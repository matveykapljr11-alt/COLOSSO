import { PGlite } from '@electric-sql/pglite';
import { readFileSync } from 'node:fs';

const DIR = new URL('..', import.meta.url).pathname;
const files = ['schema.sql','glr-xp.sql','matchmaking.sql','bracket.sql','matches.sql','team-language.sql','security-hardening.sql','anti-collusion.sql','result-reporting.sql','tournaments-glr.sql','lobby-ban-map.sql','ops-hardening.sql','realtime-and-reports.sql'];

const db = await PGlite.create();
let pass=0, fail=0;
const ok  = (m)=>{console.log('  OK  '+m); pass++;};
const bad = (m)=>{console.log('  XX  '+m); fail++;};

const prelude = `
create schema if not exists auth;
create schema if not exists storage;
create table if not exists auth.users(
  id uuid primary key default gen_random_uuid(),
  email text, raw_user_meta_data jsonb default '{}'::jsonb);
create or replace function auth.uid() returns uuid
  language sql stable as $$ select nullif(current_setting('app.uid', true),'')::uuid $$;
create table if not exists storage.buckets(id text primary key, name text, public boolean);
create table if not exists storage.objects(
  id uuid primary key default gen_random_uuid(),
  bucket_id text, name text, owner uuid);
create or replace function storage.foldername(p text) returns text[]
  language sql immutable as $$ select string_to_array(p,'/') $$;
do $$ begin create role anon; exception when duplicate_object then null; end $$;
do $$ begin create role authenticated; exception when duplicate_object then null; end $$;
do $$ begin create role service_role; exception when duplicate_object then null; end $$;
create publication supabase_realtime;
`;
await db.exec(prelude);

console.log('# 1. Apply full SQL chain');
for (const f of files){
  let sql = readFileSync(`${DIR}/${f}`,'utf8');
  sql = sql.replace(/create extension if not exists "pgcrypto";/g,'select 1;');
  try { await db.exec(sql); ok(`applied ${f}`); }
  catch(e){ bad(`applied ${f} -> ${e.message}`); }
}

const asUser = (id)=> db.exec(`set app.uid = '${id}'`);
async function mkUser(id, nick, glr=1500){
  await db.exec(`insert into auth.users(id,email,raw_user_meta_data)
    values ('${id}','${nick}@x.com', jsonb_build_object('global_name','${nick}'))`);
  await db.exec(`update profiles set nick='${nick}', glr=${glr}, xp=0, level=1 where id='${id}'`);
}
const glr = async(id)=> (await db.query(`select glr,xp,level from profiles where id='${id}'`)).rows[0];
const one = async(q)=> (await db.query(q)).rows[0];

async function mkMatch(creator, responder, {ranked=false}={}){
  await asUser(creator);
  const s = await one(`insert into scrims(creator_id,team_id) values ('${creator}',null) returning id`);
  await db.exec(`insert into scrim_responses(scrim_id,responder_id,responder_team_id,status)
                 values ('${s.id}','${responder}',null,'confirmed')`);
  const l = await one(`insert into lobbies(scrim_id,ranked,source)
                 values ('${s.id}',${ranked},'${ranked?'matchmaking':'scrim'}') returning id`);
  return l.id;
}

const U = {
  a:'11111111-1111-1111-1111-111111111111',
  b:'22222222-2222-2222-2222-222222222222',
  c:'33333333-3333-3333-3333-333333333333',
  d:'44444444-4444-4444-4444-444444444444',
};
await mkUser(U.a,'Alpha'); await mkUser(U.b,'Bravo');
await mkUser(U.c,'Charlie'); await mkUser(U.d,'Delta');
const Ue='55555555-5555-5555-5555-555555555555', Uf='66666666-6666-6666-6666-666666666666';
await mkUser(Ue,'Echo'); await mkUser(Uf,'Foxtrot');

console.log('# 2. Mechanism 1 - scrim (self-arranged) gives 0 GLR');
{
  const lob = await mkMatch(U.a,U.b,{ranked:false});
  await asUser(U.a);
  await db.exec(`select finish_match(true,'${lob}',null,null)`);
  const A=await glr(U.a), B=await glr(U.b);
  (A.glr===1500 && B.glr===1500) ? ok(`GLR unchanged (A=${A.glr} B=${B.glr})`) : bad(`GLR moved on unranked A=${A.glr} B=${B.glr}`);
  const st=await one(`select glr_applied,ranked from match_settlements where lobby_id='${lob}'`);
  (st.glr_applied===0 && st.ranked===false) ? ok('settlement glr_applied=0, ranked=false') : bad(`settlement wrong ${JSON.stringify(st)}`);
  (A.xp>0) ? ok(`XP still granted on friendly (A.xp=${A.xp})`) : bad('no XP on friendly');
}

console.log('# 3. Mechanism 2 - ranked zero-sum Elo (1500 vs 1500, K=32)');
await db.exec(`update profiles set glr=1500,xp=0,level=1 where id in ('${U.c}','${U.d}')`);
{
  const lob = await mkMatch(U.c,U.d,{ranked:true});
  await asUser(U.c);
  await db.exec(`select finish_match(true,'${lob}',null,null)`);
  const C=await glr(U.c), D=await glr(U.d);
  (C.glr===1516 && D.glr===1484) ? ok(`zero-sum C=+16 (${C.glr}), D=-16 (${D.glr})`) : bad(`expected 1516/1484 got ${C.glr}/${D.glr}`);
  ((C.glr-1500)===(1500-D.glr)) ? ok('gain == loss (conserved)') : bad('not conserved');
}

console.log('# 4. Idempotency - second finish_match does not re-award');
{
  const lob = await mkMatch(U.a,U.b,{ranked:true});
  await db.exec(`update profiles set glr=1500,xp=0,level=1 where id in ('${U.a}','${U.b}')`);
  await asUser(U.a); await db.exec(`select finish_match(true,'${lob}',null,null)`);
  const A1=await glr(U.a);
  await asUser(U.b); const r=await one(`select * from finish_match(false,'${lob}',null,null)`);
  const A2=await glr(U.a), B=await glr(U.b);
  (A1.glr===A2.glr) ? ok(`A unchanged on 2nd call (${A2.glr})`) : bad(`A changed ${A1.glr}->${A2.glr}`);
  (r.glr===B.glr) ? ok(`2nd caller got own standing back (glr=${r.glr})`) : bad('idempotent return wrong');
  const cnt=await one(`select count(*)::int c from match_settlements where lobby_id='${lob}'`);
  (cnt.c===1) ? ok('exactly one settlement row') : bad(`settlements=${cnt.c}`);
}

console.log('# 5. Mechanism 3 - rematch decay (16, 8, 5, 4, 0)');
{
  const expect=[16,8,5,4,0];
  const got=[];
  for(let i=0;i<5;i++){
    await db.exec(`update profiles set glr=1500 where id in ('${Ue}','${Uf}')`);
    const lob = await mkMatch(Ue,Uf,{ranked:true});
    await asUser(Ue); await db.exec(`select finish_match(true,'${lob}',null,null)`);
    const st=await one(`select glr_applied from match_settlements where lobby_id='${lob}'`);
    got.push(st.glr_applied);
  }
  JSON.stringify(got)===JSON.stringify(expect) ? ok(`decay sequence ${JSON.stringify(got)}`) : bad(`decay got ${JSON.stringify(got)} expected ${JSON.stringify(expect)}`);
}

console.log('# 6. Mechanism 3 - daily gain counter');
{
  const n=await one(`select _ranked_gains_today('${U.c}') c`);
  (n.c>0) ? ok(`_ranked_gains_today(Charlie)=${n.c}`) : bad('counter is zero');
}

console.log('# 7. Anomaly scan');
{
  const n=await one(`select scan_anomalies() c`);
  ok(`scan_anomalies() ran, ${n.c} flags`);
  const rp=await one(`select count(*)::int c from anti_cheat_flags where signal='repeat_pair'`);
  (rp.c>=1) ? ok(`repeat_pair flagged (C vs D played repeatedly)`) : bad('no repeat_pair flag');
}


const uid=()=>crypto.randomUUID();
async function mkTeam(name, owner, glr=1500){
  const t=await one(`insert into teams(name,slug,owner_id,glr) values ('${name}','${name.toLowerCase()}','${owner}',${glr}) returning id`);
  await db.exec(`insert into team_members(team_id,profile_id,is_captain) values ('${t.id}','${owner}',true)`);
  return t.id;
}
async function report(u, lid, won){ await asUser(u);
  let r=(await db.query(`select report_result('${lid}', ${won}, null, null) r`)).rows[0].r;
  if(typeof r==='string') r=JSON.parse(r); return r; }

console.log('# 8. report_result - both sides agree -> settled (zero-sum)');
{
  const A=uid(),B=uid(); await mkUser(A,'Rep_A'); await mkUser(B,'Rep_B');
  const lob=await mkMatch(A,B,{ranked:true});
  const r1=await report(A,lob,true);   // A claims A won
  const r2=await report(B,lob,false);  // B lost -> also claims A won
  (r1.status==='pending') ? ok('1st report pending') : bad('expected pending got '+r1.status);
  (r2.status==='settled') ? ok('2nd report settles') : bad('expected settled got '+r2.status);
  const a=await glr(A), b=await glr(B);
  (a.glr===1516 && b.glr===1484) ? ok(`agreed settle zero-sum (A=${a.glr} B=${b.glr})`) : bad(`expected 1516/1484 got ${a.glr}/${b.glr}`);
}

console.log('# 9. report_result - conflict -> dispute, no GLR moves');
let disLob=null, dA=null, dB=null;
{
  dA=uid(); dB=uid(); await mkUser(dA,'Dis_A'); await mkUser(dB,'Dis_B');
  disLob=await mkMatch(dA,dB,{ranked:true});
  const r1=await report(dA,disLob,true);   // A claims A
  const r2=await report(dB,disLob,true);   // B claims B  -> conflict
  (r2.status==='disputed') ? ok('conflict -> disputed') : bad('expected disputed got '+r2.status);
  const lb=await one(`select disputed from lobbies where id='${disLob}'`);
  (lb.disputed===true) ? ok('lobby.disputed=true') : bad('lobby not flagged disputed');
  const a=await glr(dA), b=await glr(dB);
  (a.glr===1500 && b.glr===1500) ? ok('no GLR moved while disputed') : bad(`GLR moved during dispute ${a.glr}/${b.glr}`);
  const d=await one(`select count(*)::int c from disputes where lobby_id='${disLob}' and status='open'`);
  (d.c===1) ? ok('open dispute row exists') : bad('no open dispute');
}

console.log('# 10. resolve_dispute (admin) -> settle + trust penalty for false claim');
{
  const adm=uid(); await mkUser(adm,'Admin'); await db.exec(`update profiles set is_admin=true where id='${adm}'`);
  await asUser(adm);
  let rr=(await db.query(`select resolve_dispute('${disLob}','A') r`)).rows[0].r; if(typeof rr==='string')rr=JSON.parse(rr);
  (rr.status==='resolved') ? ok('admin resolved dispute') : bad('resolve failed '+JSON.stringify(rr));
  const a=await glr(dA), b=await glr(dB);
  (a.glr===1516 && b.glr===1484) ? ok(`resolved settle (A=${a.glr} B=${b.glr})`) : bad(`expected 1516/1484 got ${a.glr}/${b.glr}`);
  const tb=await one(`select trust from profiles where id='${dB}'`);   // B falsely claimed B
  (tb.trust===95) ? ok('false reporter trust docked 100->95') : bad('trust not docked, got '+tb.trust);
  const dd=await one(`select status from disputes where lobby_id='${disLob}'`);
  (dd.status==='resolved') ? ok('dispute marked resolved') : bad('dispute not resolved');
}

console.log('# 11. tournament: organizer report -> team GLR + member GLR + advance');
{
  const o1=uid(),o2=uid(); await mkUser(o1,'Owner1'); await mkUser(o2,'Owner2');
  const t1=await mkTeam('LOUD',o1,1500), t2=await mkTeam('Fluxo',o2,1500);
  await asUser(o1);
  const trn=await one(`insert into tournaments(name,organizer_id,status) values ('Copa Teste','${o1}','reg_open') returning id`);
  await db.exec(`insert into tournament_registrations(tournament_id,team_id,registered_by) values ('${trn.id}','${t1}','${o1}'),('${trn.id}','${t2}','${o1}')`);
  await db.exec(`select seed_bracket('${trn.id}')`);
  let rr=(await db.query(`select report_tournament_match('${trn.id}',0,0,'${t1}','13','7') r`)).rows[0].r; if(typeof rr==='string')rr=JSON.parse(rr);
  (rr.status==='champion') ? ok('final reported -> champion') : bad('expected champion got '+rr.status);
  const tw=await one(`select glr,wins from teams where id='${t1}'`), tl=await one(`select glr,losses from teams where id='${t2}'`);
  (tw.glr===1516 && tl.glr===1484) ? ok(`team GLR zero-sum (W=${tw.glr} L=${tl.glr})`) : bad(`team glr ${tw.glr}/${tl.glr}`);
  const mw=await glr(o1), ml=await glr(o2);
  (mw.glr===1516 && ml.glr===1484) ? ok(`member GLR applied (W=${mw.glr} L=${ml.glr})`) : bad(`member glr ${mw.glr}/${ml.glr}`);
  const st=await one(`select status from tournaments where id='${trn.id}'`);
  (st.status==='finished') ? ok('tournament finished') : bad('status '+st.status);
  const mh=await one(`select count(*)::int c from matches where kind='Torneio'`);
  (mh.c>=2) ? ok(`tournament match history written (${mh.c} rows)`) : bad('no tournament history');
}

console.log('# 12. lobby_ban_map: participant bans -> decider computed');
{
  const A=uid(),B=uid(); await mkUser(A,'Ban_A'); await mkUser(B,'Ban_B');
  const lob=await mkMatch(A,B,{ranked:false});
  await asUser(A);
  for(const mp of ['Bermuda','Kalahari','Purgatório','Alpine']){
    await db.exec(`select lobby_ban_map('${lob}','${mp}',null)`);
  }
  const l=await one(`select decider, jsonb_array_length(bans) nb from lobbies where id='${lob}'`);
  (l.nb===4 && l.decider==='Nexterra') ? ok(`4 bans -> decider=${l.decider}`) : bad(`bans=${l.nb} decider=${l.decider}`);
}

console.log('# 13. rate limit: 11th scrim in a minute is rejected');
{
  const R=uid(); await mkUser(R,'Spammer'); await asUser(R);
  let okN=0, blocked=false;
  for(let i=0;i<11;i++){
    try{ await db.exec(`insert into scrims(creator_id) values ('${R}')`); okN++; }
    catch(e){ blocked=true; }
  }
  (okN===10 && blocked) ? ok(`10 allowed, 11th blocked`) : bad(`allowed=${okN} blocked=${blocked}`);
}

console.log('# 14. content guard: blocked term in nick is rejected');
{
  const P=uid(); await mkUser(P,'Clean'); await asUser(P);
  let threw=false;
  try{ await db.exec(`update profiles set nick='xxslurxx' where id='${P}'`); }
  catch(e){ threw=true; }
  threw ? ok('blocked nickname rejected') : bad('blocked nick allowed');
}


console.log('# 15. reports: user files report, admin lists it');
{
  const R=uid(); await mkUser(R,'Reporter'); await asUser(R);
  await db.exec(`insert into reports(reporter_id,target_type,target_id,reason) values ('${R}','player','someone','toxic')`);
  const adm=uid(); await mkUser(adm,'Mod'); await db.exec(`update profiles set is_admin=true where id='${adm}'`); await asUser(adm);
  const r=(await db.query(`select count(*)::int c from list_reports('open')`)).rows[0];
  (r.c>=1)?ok(`admin sees ${r.c} report(s)`):bad('admin list empty');
}

console.log(`\nRESULT: ${pass} passed, ${fail} failed`);
process.exit(fail?1:0);
