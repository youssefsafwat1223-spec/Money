import { assert, assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import {
  eraseBackupObjects,
  MAX_REMOVE_BATCHES_PER_RUN,
  REMOVE_BATCH_SIZE,
  type StorageLike,
} from './storage_erasure.ts';

// Audit H-24 — adversarial fake-Storage tests only; no remote Storage access.
//
// NON-VACUOUS CROSS-USER ANCHOR: the malicious tracked path test fails against
// the prior helper because it sent the other user's path to service-role
// remove(), deleting the victim object.
//
// NON-VACUOUS CONVERGENCE ANCHOR: the late-upload test fails against the prior
// single-pass helper because that helper returned immediately after its first
// listing/removal, leaving the object injected after that listing recoverable.

type Entry = { name: string; id?: string | null };
type Tree = Record<string, Entry[]>;

type FakeOptions = {
  listError?: string;
  listErrorAt?: number;
  removeError?: string;
  removeErrorAt?: number;
  afterList?: (context: {
    callNumber: number;
    path: string;
    addObject: (objectPath: string, id: string) => void;
  }) => void;
};

function fakeStorage(sourceTree: Tree, opts: FakeOptions = {}) {
  const tree: Tree = Object.fromEntries(
    Object.entries(sourceTree).map(([path, entries]) => [
      path,
      entries.map((entry) => ({ ...entry })),
    ]),
  );
  const removed: string[] = [];
  const listCalls: Array<{ path: string; offset: number; limit: number }> = [];
  const removeCalls: string[][] = [];

  const addObject = (objectPath: string, id: string) => {
    const separator = objectPath.lastIndexOf('/');
    const parent = objectPath.slice(0, separator);
    const name = objectPath.slice(separator + 1);
    tree[parent] ??= [];
    if (!tree[parent].some((entry) => entry.name === name && entry.id != null)) {
      tree[parent].push({ name, id });
    }
  };

  const hasObject = (objectPath: string) => {
    const separator = objectPath.lastIndexOf('/');
    const parent = objectPath.slice(0, separator);
    const name = objectPath.slice(separator + 1);
    return (tree[parent] ?? []).some((entry) => entry.name === name && entry.id != null);
  };

  const objectPaths = () =>
    Object.entries(tree).flatMap(([parent, entries]) =>
      entries
        .filter((entry) => entry.id != null)
        .map((entry) => `${parent}/${entry.name}`)
    );

  const storage: StorageLike = {
    from(_bucket: string) {
      return {
        list(path: string, options?: { limit?: number; offset?: number }) {
          const limit = options?.limit ?? 100;
          const offset = options?.offset ?? 0;
          listCalls.push({ path, offset, limit });
          const callNumber = listCalls.length;
          if (opts.listError || opts.listErrorAt === callNumber) {
            return Promise.resolve({
              data: null,
              error: { message: opts.listError ?? `list failure ${callNumber}` },
            });
          }

          // Snapshot the returned page before invoking the hook. This models an
          // upload that lands after this list pass and is invisible to it.
          const page = (tree[path] ?? [])
            .slice(offset, offset + limit)
            .map((entry) => ({ ...entry }));
          opts.afterList?.({ callNumber, path, addObject });
          return Promise.resolve({ data: page, error: null });
        },
        remove(paths: string[]) {
          removeCalls.push([...paths]);
          const callNumber = removeCalls.length;
          if (opts.removeError || opts.removeErrorAt === callNumber) {
            return Promise.resolve({
              data: null,
              error: { message: opts.removeError ?? `remove failure ${callNumber}` },
            });
          }

          for (const objectPath of paths) {
            const separator = objectPath.lastIndexOf('/');
            const parent = objectPath.slice(0, separator);
            const name = objectPath.slice(separator + 1);
            const before = tree[parent] ?? [];
            const existed = before.some((entry) => entry.name === name && entry.id != null);
            tree[parent] = before.filter((entry) => !(entry.name === name && entry.id != null));
            if (existed) removed.push(objectPath);
          }
          return Promise.resolve({ data: paths, error: null });
        },
      };
    },
  };

  return { storage, removed, listCalls, removeCalls, hasObject, objectPaths };
}

function flatObjects(count: number): Entry[] {
  return Array.from({ length: count }, (_, index) => ({
    name: `o${index}.enc`,
    id: `id-${index}`,
  }));
}

function deepTree(userId: string, depth: number, leafCount: number): Tree {
  const tree: Tree = {};
  let directory = userId;
  for (let level = 0; level < depth; level += 1) {
    const name = `level-${level}`;
    tree[directory] = [{ name, id: null }];
    directory = `${directory}/${name}`;
  }
  tree[directory] = flatObjects(leafCount);
  return tree;
}

const USER = '11111111-1111-1111-1111-111111111111';
const OTHER_USER = '22222222-2222-2222-2222-222222222222';

Deno.test('tracked path outside the exact user prefix is never removed', async () => {
  const victimPath = `${OTHER_USER}/backup.enc`;
  const { storage, removed, removeCalls, hasObject, objectPaths } = fakeStorage({
    [USER]: [
      { name: 'backup.enc', id: 'owner-1' },
      { name: 'stray.enc', id: 'owner-2' },
    ],
    [OTHER_USER]: [{ name: 'backup.enc', id: 'victim-1' }],
  });

  const result = await eraseBackupObjects(storage, USER, victimPath);

  assertEquals(result.complete, true);
  assertEquals(result.retryable, false);
  assert(hasObject(victimPath), 'victim object was deleted by the service-role sweep');
  assert(!removed.includes(victimPath), 'foreign tracked path reached remove()');
  assert(
    removeCalls.every((paths) => paths.every((path) => path.startsWith(`${USER}/`))),
    'remove() received a path outside the exact owner prefix',
  );
  assertEquals(
    objectPaths().filter((path) => path.startsWith(`${USER}/`)),
    [],
    'the malicious tracked path must not prevent the owner prefix from being fully swept',
  );
});

Deno.test('re-checks after the first list and catches a concurrent upload', async () => {
  const earlyPath = `${USER}/early.enc`;
  const latePath = `${USER}/late.enc`;
  let injected = false;
  const { storage, removed, hasObject, listCalls } = fakeStorage(
    { [USER]: [{ name: 'early.enc', id: 'early' }] },
    {
      afterList: ({ callNumber, path, addObject }) => {
        if (!injected && callNumber === 1 && path === USER) {
          injected = true;
          addObject(latePath, 'late');
        }
      },
    },
  );

  const result = await eraseBackupObjects(storage, USER, null);

  assertEquals(result.complete, true);
  assert(listCalls.length >= 3, 'completion requires re-listing after removal');
  assert(removed.includes(earlyPath));
  assert(removed.includes(latePath), 'object uploaded after the first list survived');
  assert(!hasObject(latePath), 'late upload remains recoverable');
});

Deno.test('an empty/absent prefix is idempotent success after two empty scans', async () => {
  const { storage, removed, listCalls, removeCalls } = fakeStorage({});
  const result = await eraseBackupObjects(storage, USER, null);

  assertEquals(result, { removed: [], complete: true, retryable: false });
  assertEquals(removed, []);
  assertEquals(removeCalls.length, 0);
  assertEquals(listCalls.length, 2, 'one empty listing alone is not terminal proof');
});

Deno.test('removes an owned tracked path even when listing omits it', async () => {
  const trackedPath = `${USER}/backup.enc`;
  const { storage, removeCalls } = fakeStorage({ [USER]: [] });
  const result = await eraseBackupObjects(storage, USER, trackedPath);

  assertEquals(result.complete, true);
  assertEquals(removeCalls[0], [trackedPath]);
});

Deno.test('chunks more than one batch of objects into bounded remove calls', async () => {
  const objectCount = REMOVE_BATCH_SIZE * 2 + 37;
  const { storage, objectPaths, removeCalls } = fakeStorage({
    [USER]: flatObjects(objectCount),
  });

  const result = await eraseBackupObjects(storage, USER, null);

  assertEquals(result.complete, true);
  assertEquals(result.removed.length, objectCount);
  assertEquals(objectPaths(), []);
  assert(removeCalls.length >= 3, 'objects were not split across multiple remove calls');
  assert(
    removeCalls.every((paths) => paths.length <= REMOVE_BATCH_SIZE),
    'a remove call exceeded the bounded chunk size',
  );
});

Deno.test('pages a directory listing to reach objects after the first page', async () => {
  const pagedPath = `${USER}/after-page.enc`;
  const firstPageFolders = Array.from({ length: 100 }, (_, index) => ({
    name: `folder-${index}`,
    id: null,
  }));
  const { storage, hasObject, listCalls } = fakeStorage({
    [USER]: [...firstPageFolders, { name: 'after-page.enc', id: 'paged' }],
  });

  const result = await eraseBackupObjects(storage, USER, null);

  assertEquals(result.complete, true);
  assert(!hasObject(pagedPath), 'object beyond the first list page survived');
  assert(
    listCalls.some((call) => call.path === USER && call.offset === 100),
    'the second directory page was never listed',
  );
});

Deno.test('deep nesting is resumable and never falsely complete at the work limit', async () => {
  const objectCount = REMOVE_BATCH_SIZE * MAX_REMOVE_BATCHES_PER_RUN + 1;
  const { storage, objectPaths, removeCalls } = fakeStorage(deepTree(USER, 32, objectCount));

  const first = await eraseBackupObjects(storage, USER, null);

  assertEquals(first.complete, false);
  assertEquals(first.retryable, true);
  assert(first.error?.includes('work_limit_reached'));
  assertEquals(removeCalls.length, MAX_REMOVE_BATCHES_PER_RUN);
  assertEquals(objectPaths().length, 1, 'bounded first run should leave retryable work');
  assert(
    removeCalls.every((paths) => paths.length <= REMOVE_BATCH_SIZE),
    'deep-tree removal exceeded the chunk bound',
  );

  const retry = await eraseBackupObjects(storage, USER, null);

  assertEquals(retry.complete, true);
  assertEquals(retry.retryable, false);
  assertEquals(objectPaths(), []);
});

Deno.test('a real list error after partial progress is incomplete and retryable', async () => {
  const { storage, objectPaths, removeCalls } = fakeStorage(
    { [USER]: flatObjects(REMOVE_BATCH_SIZE + 1) },
    { listErrorAt: 2 },
  );

  const result = await eraseBackupObjects(storage, USER, null);

  assertEquals(result.complete, false);
  assertEquals(result.retryable, true);
  assert(result.error?.includes('list_prefix'), 'list error must surface');
  assertEquals(removeCalls.length, 1);
  assertEquals(objectPaths().length, 1, 'remaining object proves completion was not claimed');
});

Deno.test('a real remove error after partial progress is incomplete and retryable', async () => {
  const { storage, objectPaths, removeCalls } = fakeStorage(
    { [USER]: flatObjects(REMOVE_BATCH_SIZE * 2 + 1) },
    { removeErrorAt: 2 },
  );

  const result = await eraseBackupObjects(storage, USER, null);

  assertEquals(result.complete, false);
  assertEquals(result.retryable, true);
  assert(result.error?.includes('remove_objects'), 'remove error must surface');
  assertEquals(removeCalls.length, 2);
  assertEquals(
    objectPaths().length,
    REMOVE_BATCH_SIZE + 1,
    'failed batch remains recoverable and must prevent terminal completion',
  );
});
