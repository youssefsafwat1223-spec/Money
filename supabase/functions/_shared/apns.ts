type ApnsEnvironment = 'sandbox' | 'production';

type ApnsMessage = {
  token: string;
  environment: ApnsEnvironment;
  payloadId: string;
  title: string;
  body: string;
  notificationType: string;
  transactionId?: string;
  smartInboxItemId?: string;
};

type ApnsResult =
  | { ok: true; apnsId: string | null }
  | { ok: false; reason: string };

const encoder = new TextEncoder();
let cachedJwt: { token: string; expiresAt: number } | null = null;

export async function sendCapturePush(message: ApnsMessage): Promise<ApnsResult> {
  const keyId = Deno.env.get('APNS_KEY_ID') ?? '';
  const teamId = Deno.env.get('APNS_TEAM_ID') ?? '';
  const bundleId = Deno.env.get('APNS_BUNDLE_ID') ?? '';
  const privateKey = Deno.env.get('APNS_PRIVATE_KEY') ?? '';
  if (!keyId || !teamId || !bundleId || !privateKey) {
    return { ok: false, reason: 'apns_not_configured' };
  }

  try {
    const jwt = await apnsJwt({ keyId, teamId, privateKey });
    const host = message.environment === 'sandbox'
      ? 'https://api.sandbox.push.apple.com'
      : 'https://api.push.apple.com';
    // Bounded so the whole process-ios-sms request stays inside the App
    // Intent's 8s client budget — an APNs hang otherwise guarantees a client
    // timeout and a duplicate local fallback banner.
    const response = await fetch(`${host}/3/device/${message.token}`, {
      signal: AbortSignal.timeout(2500),
      method: 'POST',
      headers: {
        authorization: `bearer ${jwt}`,
        'apns-topic': bundleId,
        'apns-push-type': 'alert',
        'apns-priority': '10',
        'apns-collapse-id': `qirsh-capture-${message.payloadId}`,
        'content-type': 'application/json',
      },
      body: JSON.stringify({
        aps: {
          alert: {
            title: message.title,
            body: message.body,
          },
          sound: 'default',
        },
        payloadId: message.payloadId,
        transactionId: message.transactionId ?? '',
        smartInboxItemId: message.smartInboxItemId ?? '',
        notificationType: message.notificationType,
        source: 'ios_shortcut',
      }),
    });
    if (!response.ok) {
      const reason = await safeReason(response);
      return { ok: false, reason: `apns_${response.status}_${reason}` };
    }
    return { ok: true, apnsId: response.headers.get('apns-id') };
  } catch (error) {
    return { ok: false, reason: `apns_exception_${String(error).slice(0, 80)}` };
  }
}

async function apnsJwt(input: {
  keyId: string;
  teamId: string;
  privateKey: string;
}): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (cachedJwt && cachedJwt.expiresAt > now + 60) return cachedJwt.token;

  const header = base64UrlJson({ alg: 'ES256', kid: input.keyId });
  const claims = base64UrlJson({ iss: input.teamId, iat: now });
  const signingInput = `${header}.${claims}`;
  const key = await crypto.subtle.importKey(
    'pkcs8',
    pemToArrayBuffer(input.privateKey),
    { name: 'ECDSA', namedCurve: 'P-256' },
    false,
    ['sign'],
  );
  const derSignature = new Uint8Array(await crypto.subtle.sign(
    { name: 'ECDSA', hash: 'SHA-256' },
    key,
    encoder.encode(signingInput),
  ));
  const jwt = `${signingInput}.${base64Url(derSignature)}`;
  cachedJwt = { token: jwt, expiresAt: now + 20 * 60 };
  return jwt;
}

function base64UrlJson(value: Record<string, unknown>): string {
  return base64Url(encoder.encode(JSON.stringify(value)));
}

function base64Url(bytes: Uint8Array): string {
  let binary = '';
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll('+', '-').replaceAll('/', '_').replaceAll('=', '');
}

function pemToArrayBuffer(pem: string): ArrayBuffer {
  const base64 = pem
    .replace(/-----BEGIN PRIVATE KEY-----/g, '')
    .replace(/-----END PRIVATE KEY-----/g, '')
    .replace(/\s+/g, '');
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes.buffer;
}

async function safeReason(response: Response): Promise<string> {
  try {
    const data = await response.json();
    return String(data?.reason ?? 'failed').slice(0, 80);
  } catch (_) {
    return 'failed';
  }
}
