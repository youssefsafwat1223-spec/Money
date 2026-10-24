// Handler for the account-deletion recovery worker. DRAFT - NOT DEPLOYED.
//
// Authenticated exactly like cron-daily-reminders: Authorization: Bearer
// <dedicated secret>, constant-time compared, failing closed on an empty secret.
// Runs coordinator.processNext() up to maxJobs times and returns COUNTS ONLY:
// no job id, uid, token or provider text ever appears in the response.

import { timingSafeEqual } from '../_shared/capture_auth.ts';
import type { RunOutcome } from '../_shared/account_deletion_coordinator.ts';

export const DEFAULT_MAX_JOBS = 5;
export const HARD_MAX_JOBS = 25;

export interface WorkerCoordinatorLike {
  processNext(workerId: string): Promise<RunOutcome>;
}

export function createWorkerHandler(deps: {
  coordinator: () => Promise<WorkerCoordinatorLike> | WorkerCoordinatorLike;
  workerSecret: string;
  workerId: string;
  maxJobs?: number;
}) {
  const max = Math.min(Math.max(Math.floor(deps.maxJobs ?? DEFAULT_MAX_JOBS), 1), HARD_MAX_JOBS);
  return async (req: Request): Promise<Response> => {
    const authHeader = req.headers.get('authorization') ?? '';
    const token = authHeader.startsWith('Bearer ') ? authHeader.slice(7) : '';
    if (!deps.workerSecret || !timingSafeEqual(token, deps.workerSecret)) {
      return new Response('Forbidden', { status: 403 });
    }
    const counts = { processed: 0, completed: 0, retry_scheduled: 0, failed: 0, other: 0 };
    try {
      const coordinator = await deps.coordinator();
      for (let i = 0; i < max; i++) {
        const out = await coordinator.processNext(deps.workerId);
        if (out.outcome === 'no_work') break;
        counts.processed++;
        if (out.outcome === 'completed') counts.completed++;
        else if (out.outcome === 'retry_scheduled') counts.retry_scheduled++;
        else if (out.outcome === 'failed') counts.failed++;
        else counts.other++;
      }
    } catch {
      return new Response(JSON.stringify({ status: 'error', ...counts }), {
        status: 500,
        headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' },
      });
    }
    return new Response(JSON.stringify({ status: 'ok', ...counts }), {
      headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' },
    });
  };
}
