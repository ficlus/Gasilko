// Independent PostgreSQL connections, disposable local stack only.
import { execFileSync, spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
const config = JSON.parse(execFileSync('supabase', ['status', '-o', 'json'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }));
if (!['http://127.0.0.1:54321', 'http://localhost:54321'].includes(config.API_URL)) throw Error('Local stack only');
const args = ['exec', '-i', 'supabase_db_gasilko', 'psql', '-U', 'postgres', '-d', 'postgres', '-qAt', '-v', 'ON_ERROR_STOP=1'];
const sql = query => execFileSync('docker', args, { input: query, encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'] }).trim();
const actor = randomUUID(), orgs = [randomUUID(), randomUUID()], hydrants = Array.from({ length: 14 }, () => randomUUID());
const prefixes = orgs.map(id => `M21-C-${id.toUpperCase()}`);
let count = 0;
function check(ok, label) { if (!ok) throw Error(label); console.log(`ok ${++count} - ${label}`); }
function connection(query) {
  return new Promise(resolve => {
    const child = spawn('docker', args, { stdio: ['pipe', 'pipe', 'pipe'] });
    let output = '', error = '';
    child.stdout.on('data', d => output += d);
    child.stderr.on('data', d => error += d);
    child.on('error', e => resolve({ ok: false, output, error: e.message }));
    child.on('close', code => resolve({ ok: code === 0, output, error }));
    child.stdin.end(query);
  });
}
const allocate = (n, org = 0) => `select private.assign_hydrant_code('${orgs[org]}','${hydrants[n]}','${actor}')`;
const wrap = (query, isolation = 'read committed', ending = 'commit') =>
  `begin isolation level ${isolation}; select count(*) from public.countries; select pg_sleep(0.2); ${query}; select pg_sleep(0.2); ${ending};`;
try {
  sql(`insert into auth.users(id) values('${actor}');` +
    orgs.map((id, n) => `insert into public.organizations(id,name,code,type) values('${id}','Hydrant concurrency','${prefixes[n]}','OTHER');`).join('\n') +
    hydrants.map((id, n) => `insert into public.hydrants(id,organization_id,hydrant_type_id,address,created_by,updated_by) values('${id}','${orgs[n === 10 ? 1 : 0]}','30000000-0000-4000-8000-000000000001','Test address','${actor}','${actor}');`).join('\n'));
  let results = await Promise.all(Array.from({ length: 8 }, (_, n) => connection(wrap(allocate(n)))));
  check(results.every(r => r.ok), 'eight simultaneous first allocations commit');
  check(sql(`select count(distinct code) from public.hydrants where organization_id='${orgs[0]}' and code is not null`) === '8', 'concurrent allocations unique');
  check(sql(`select last_value from private.hydrant_code_counters where organization_id='${orgs[0]}'`) === '8', 'counter consumed exactly eight numbers');
  check(sql(`select bool_and(code ~ '-H-00000[1-8]$' and version=2) from public.hydrants where organization_id='${orgs[0]}' and code is not null`) === 't', 'all codes formatted and versioned once');
  results = await Promise.all(Array.from({ length: 6 }, () => connection(wrap(allocate(8)))));
  check(results.every(r => r.ok && r.output.includes(`${prefixes[0]}-H-000009`)), 'six same-hydrant allocations return one code');
  check(sql(`select last_value from private.hydrant_code_counters where organization_id='${orgs[0]}'`) === '9', 'same-hydrant retries consume one number');
  check(sql(`select version from public.hydrants where id='${hydrants[8]}'`) === '2', 'same-hydrant retries cause one version change');
  results = await Promise.all([connection(wrap(allocate(9))), connection(wrap(allocate(10, 1)))]);
  check(results.every(r => r.ok), 'independent organizations allocate concurrently');
  check(sql(`select code from public.hydrants where id='${hydrants[10]}'`) === `${prefixes[1]}-H-000001`, 'independent organization starts at one');
  const before = sql(`select last_value from private.hydrant_code_counters where organization_id='${orgs[0]}'`);
  check((await connection(wrap(allocate(11), 'read committed', 'rollback'))).ok, 'allocation transaction can roll back');
  check(sql(`select last_value from private.hydrant_code_counters where organization_id='${orgs[0]}'`) === before &&
    sql(`select code is null and version=1 from public.hydrants where id='${hydrants[11]}'`) === 't' &&
    sql(`select count(*) from private.hydrant_code_assignments where hydrant_id='${hydrants[11]}'`) === '0', 'rollback restores code counter ledger and version together');
  results = await Promise.all([connection(wrap(allocate(11), 'repeatable read')), connection(wrap(allocate(12), 'repeatable read'))]);
  check(results.some(r => r.ok) && results.every(r => r.ok || /could not serialize access|deadlock detected/.test(r.error)), 'strong isolation commits or safely aborts stale allocator');
  sql(`${allocate(11)}; ${allocate(12)};`);
  check(sql(`select count(distinct code) from public.hydrants where id in ('${hydrants[11]}','${hydrants[12]}')`) === '2', 'whole-transaction retry preserves unique codes');
  results = await Promise.all([
    connection(wrap(allocate(13))),
    connection(wrap(`update public.organizations set code='${prefixes[0]}-RENAMED' where id='${orgs[0]}'`)),
  ]);
  check(results.every(r => r.ok), 'organization rename and allocation serialize safely');
  check(sql(`select code from public.hydrants where id='${hydrants[13]}'`) === `${prefixes[0]}-H-000013`, 'concurrent rename preserves frozen prefix and sequence');
  check(sql(`select count(*)=count(distinct code) from private.hydrant_code_assignments where organization_id in ('${orgs[0]}','${orgs[1]}')`) === 't', 'all committed reservations remain unique');
  console.log(`Hydrant concurrency: ${count} assertions passed`);
} catch (error) { console.error(error.message); process.exitCode = 1; }
// Fixtures remain in the disposable stack until reset; no production access.
