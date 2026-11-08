// Pemakaian (hanya oleh run_stack.sh): node jwt_cli.mjs <secret> <anon|service_role>
import { apiKey } from './jwt.mjs';

const [secret, role] = process.argv.slice(2);
if (!secret || !['anon', 'service_role'].includes(role)) {
  console.error('pemakaian: jwt_cli.mjs <secret> <anon|service_role>');
  process.exit(64);
}
process.stdout.write(apiKey(secret, role));
