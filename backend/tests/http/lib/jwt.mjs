// HS256 JWT minimal untuk TES LOKAL: membuat anon/service key stack lokal dan token palsu/kedaluwarsa
// untuk uji negatif. Secret berasal dari run_stack.sh (acak per run) dan tidak pernah dicetak.
import { createHmac } from 'node:crypto';

const b64url = (buf) => Buffer.from(buf).toString('base64').replace(/=+$/, '').replace(/\+/g, '-').replace(/\//g, '_');

export function signHS256(payload, secret, header = { alg: 'HS256', typ: 'JWT' }) {
  const h = b64url(JSON.stringify(header));
  const p = b64url(JSON.stringify(payload));
  const sig = b64url(createHmac('sha256', secret).update(`${h}.${p}`).digest());
  return `${h}.${p}.${sig}`;
}

export function decodePayload(token) {
  const part = token.split('.')[1];
  return JSON.parse(Buffer.from(part.replace(/-/g, '+').replace(/_/g, '/'), 'base64').toString('utf8'));
}

// Token "alg: none" tanpa tanda tangan (harus ditolak).
export function unsignedToken(payload) {
  return `${b64url(JSON.stringify({ alg: 'none', typ: 'JWT' }))}.${b64url(JSON.stringify(payload))}.`;
}

// Ganti payload tetapi pertahankan tanda tangan asli (harus ditolak).
export function tamperPayload(token, patch) {
  const [h, , s] = token.split('.');
  const payload = { ...decodePayload(token), ...patch };
  return `${h}.${b64url(JSON.stringify(payload))}.${s}`;
}

export function apiKey(secret, role) {
  const now = Math.floor(Date.now() / 1000);
  return signHS256({ iss: 'sendfood-local-stack', role, iat: now, exp: now + 6 * 3600 }, secret);
}
