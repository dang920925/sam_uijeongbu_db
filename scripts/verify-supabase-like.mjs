#!/usr/bin/env node
// ----------------------------------------------------------------------
// Supabase 같은 DB 에서 전체 마이그레이션 검증 — `pnpm verify:supabase-like`
//
// 로컬 docker DB(컨테이너 sam-uijeongbu-db)에 일회용 DB 를 만들어 Flyway 를 돌리고, 끝에 모두 지운다.
// Supabase 를 흉내 내는 것(Supabase 에만 있어 로컬 Postgres 에서는 조건부로 건너뛰는 부분을 실제로 태운다):
//   - 클러스터 역할 anon · authenticated, public 스키마 USAGE,
//   - 마이그레이션 계정(postgres)의 기본 권한 ALL(테이블 · 시퀀스 · 함수) → 새 테이블에 anon 권한이 붙는 상황,
//   - storage 스키마와 storage.buckets 테이블(V1_0_3 이 media 버킷을 만든다).
// 확인: ① 빈 DB 전체 적용 → 2회째 up to date → check-security.sql 0행 → anon · authenticated 로 public 접근 거부
//       → media 버킷 설정(public · 10MB · jpeg/png/webp) → 런타임 계정(sam_app 멤버)이 읽기·쓰기 가능하고 TRUNCATE 거부
//       ② V1_0_1 까지 적용(anon 권한이 남은 상태를 검사 SQL 이 잡는지) → 나머지 적용 → 0행
//       ③ V1_0_3 까지 + 운영 같은 기존 데이터(공연·반·회차) → V1_0_4 적용: 기존 회차 유지(price NULL·booking_enabled true),
//          반 삭제 시 회차가 남음(class_id SET NULL), 런타임 계정의 입장 기록 UPDATE 거부
//       ④ V1_0_3 까지 + 같은 공연·날짜·시각 회차 2개 → V1_0_4 가 한국어 오류로 실패하고 1.0.3 에 머문다(롤백)
// 지키는 것: 원본 sam_uijeongbu 는 건드리지 않는다(DB 이름은 fixture_supa_ 만). anon · authenticated 는
//           시작 때 없을 때만 만들고 끝에 지운다. 결과 표를 출력하고 하나라도 틀리면 exit 1.
// ----------------------------------------------------------------------
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import { FLYWAY_IMAGE } from './flyway-args.mjs';

const DB_ROOT = resolve(fileURLToPath(new URL('..', import.meta.url)));
const CONTAINER = 'sam-uijeongbu-db';
const HOST_PORT = 4110;
const DB_PREFIX = 'fixture_supa_';
const DB_EMPTY = `${DB_PREFIX}empty`;
const DB_UPGRADE = `${DB_PREFIX}upgrade`;
const DB_BOOKING = `${DB_PREFIX}booking`;
const DB_DUPLICATE = `${DB_PREFIX}duplicate`;
const SUPABASE_ROLES = ['anon', 'authenticated'];
const RUNTIME_LOGIN = `${DB_PREFIX}api`;
const SQL_DIR = join(DB_ROOT, 'sql');
const CHECK_SQL = readFileSync(join(DB_ROOT, 'scripts/check-security.sql'), 'utf8');
const APP_TABLES = [
  'admins', 'performances', 'performance_detail_images', 'classes', 'class_days', 'shows', 'members',
  'actor_profiles', 'actor_filmographies', 'applications', 'galleries', 'schedules', 'staff', 'popups',
  // V1_0_4(예매 1단계)
  'booking_policies', 'price_tiers', 'reservations', 'reservation_items', 'admission_logs',
];

const results = [];

function record(scenario, item, expected, actual) {
  const pass = String(expected) === String(actual);
  results.push({ scenario, item, expected: String(expected), actual: String(actual), pass });
  console.log(`  [${pass ? '통과' : '실패'}] ${item} — 기대 ${expected} · 실제 ${actual}`);
}

function assertFixtureDb(db) {
  if (!db.startsWith(DB_PREFIX)) throw new Error(`일회용 DB 이름이 아니다: ${db}`);
}

function psql(db, sql, user = 'postgres') {
  const run = spawnSync(
    'docker',
    ['exec', '-i', CONTAINER, 'psql', '-U', user, '-X', '-q', '-v', 'ON_ERROR_STOP=1', '-At', '-F', '|', '-d', db],
    { input: sql, encoding: 'utf8' }
  );
  return { ok: run.status === 0, out: run.stdout ?? '', err: run.stderr ?? '' };
}

function psqlOrThrow(db, sql) {
  const result = psql(db, sql);
  if (!result.ok) throw new Error(`psql 실패(${db}): ${result.err.trim()}`);
  return result.out;
}

function rows(out) {
  return out.split('\n').filter((line) => line.length > 0);
}

function flyway(db, args) {
  assertFixtureDb(db);
  const run = spawnSync(
    'docker',
    [
      'run', '--rm', '--add-host=host.docker.internal:host-gateway', '-v', `${SQL_DIR}:/flyway/sql:ro`, FLYWAY_IMAGE,
      `-url=jdbc:postgresql://host.docker.internal:${HOST_PORT}/${db}`, '-user=postgres',
      '-locations=filesystem:/flyway/sql', '-schemas=public', '-baselineOnMigrate=true', '-baselineVersion=0',
      '-cleanDisabled=true', ...args,
    ],
    { encoding: 'utf8' }
  );
  return { ok: run.status === 0, out: `${run.stdout ?? ''}${run.stderr ?? ''}` };
}

function firstErrorLine(out) {
  const lines = out.split('\n');
  return (lines.find((l) => /^Message\s+:/.test(l)) ?? lines.find((l) => /ERROR/.test(l)) ?? lines.at(-1) ?? '').trim();
}

function dropFixtureDb(db) {
  assertFixtureDb(db);
  psql('postgres', `DROP DATABASE IF EXISTS ${db} WITH (FORCE);`);
}

/** Supabase 흉내 — 역할 기본 권한 + storage.buckets stub */
function createSupabaseLikeDb(db) {
  dropFixtureDb(db);
  psqlOrThrow('postgres', `CREATE DATABASE ${db};`);
  psqlOrThrow(
    db,
    `GRANT USAGE ON SCHEMA public TO anon, authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES TO anon, authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES TO anon, authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON FUNCTIONS TO anon, authenticated;
CREATE SCHEMA storage;
CREATE TABLE storage.buckets (
    id                 text PRIMARY KEY,
    name               text NOT NULL,
    owner              uuid NULL,
    public             boolean DEFAULT false,
    file_size_limit    bigint NULL,
    allowed_mime_types text[] NULL,
    created_at         timestamptz DEFAULT now(),
    updated_at         timestamptz DEFAULT now()
);`
  );
}

function verifyAnonDenied(scenario, db) {
  for (const role of SUPABASE_ROLES) {
    for (const table of ['applications', 'admins', 'performances', 'flyway_schema_history']) {
      const result = psql(db, `SET ROLE ${role};\nSELECT 1 FROM public.${table} LIMIT 1;`);
      const outcome = result.ok ? '성공' : /permission denied/.test(result.err) ? '거부' : result.err.trim();
      record(scenario, `${role} 로 ${table} SELECT`, '거부', outcome);
    }
  }
}

function verifyRuntimeRole(scenario, db) {
  const insert = psql(
    db,
    `INSERT INTO performances (id, title, type, status) VALUES ('00000000-0000-7000-8000-000000000001', 'fixture-supa', 'PLAY', 'ONGOING');
SELECT count(*) FROM performances;`,
    RUNTIME_LOGIN
  );
  record(scenario, '런타임 계정 INSERT·SELECT(RLS 정책 sam_app_all)', '1', insert.ok ? rows(insert.out).at(-1) : insert.err.trim());
  const truncate = psql(db, 'TRUNCATE performances;', RUNTIME_LOGIN);
  record(scenario, '런타임 계정 TRUNCATE', '거부', truncate.ok ? '성공' : /permission denied/.test(truncate.err) ? '거부' : truncate.err.trim());
  const deleteSoft = psql(db, 'DELETE FROM performances;', RUNTIME_LOGIN);
  record(scenario, '런타임 계정 소프트 삭제 테이블 DELETE', '거부', deleteSoft.ok ? '성공' : /permission denied/.test(deleteSoft.err) ? '거부' : deleteSoft.err.trim());
  const rls = rows(
    psqlOrThrow(db, `SELECT count(*) FROM pg_class WHERE relnamespace = 'public'::regnamespace AND relkind = 'r' AND relrowsecurity AND relname = ANY(ARRAY['${APP_TABLES.join("','")}']);`)
  );
  record(scenario, 'RLS 켜진 앱 테이블 수', APP_TABLES.length, rls[0]);
}

function scenarioEmpty() {
  const s = '① 빈 DB';
  console.log(`\n== ${s} (${DB_EMPTY})`);
  createSupabaseLikeDb(DB_EMPTY);
  const first = flyway(DB_EMPTY, ['migrate']);
  record(s, '전체 마이그레이션', '성공', first.ok ? '성공' : `실패 — ${firstErrorLine(first.out)}`);
  if (!first.ok) return;
  const second = flyway(DB_EMPTY, ['migrate']);
  record(s, '2회째 migrate 가 up to date', '예', second.ok && /is up to date/.test(second.out) ? '예' : '아니오');
  const violations = rows(psqlOrThrow(DB_EMPTY, CHECK_SQL));
  record(s, 'check-security.sql 행 수', 0, violations.length);
  violations.forEach((line) => console.log(`    위반: ${line}`));
  verifyAnonDenied(s, DB_EMPTY);
  const bucket = rows(
    psqlOrThrow(DB_EMPTY, `SELECT public, file_size_limit, array_to_string(allowed_mime_types, ',') FROM storage.buckets WHERE id = 'media';`)
  );
  record(s, 'media 버킷(public|10MB|jpeg,png,webp)', 't|10485760|image/jpeg,image/png,image/webp', bucket[0] ?? '없음');
  verifyRuntimeRole(s, DB_EMPTY);
}

function scenarioUpgrade() {
  const s = '② V1_0_1 → 나머지';
  console.log(`\n== ${s} (${DB_UPGRADE})`);
  createSupabaseLikeDb(DB_UPGRADE);
  const before = flyway(DB_UPGRADE, ['migrate', '-target=1.0.1']);
  record(s, 'V1_0_1 까지 적용', '성공', before.ok ? '성공' : `실패 — ${firstErrorLine(before.out)}`);
  if (!before.ok) return;
  const beforeCheck = rows(psqlOrThrow(DB_UPGRADE, CHECK_SQL));
  record(s, 'V1_0_2 전 검사 SQL 이 anon 권한·RLS 꺼짐을 찾는다', '예', beforeCheck.length > 0 ? '예' : '아니오');
  const after = flyway(DB_UPGRADE, ['migrate']);
  record(s, '나머지 적용', '성공', after.ok ? '성공' : `실패 — ${firstErrorLine(after.out)}`);
  if (!after.ok) return;
  record(s, 'check-security.sql 행 수', 0, rows(psqlOrThrow(DB_UPGRADE, CHECK_SQL)).length);
}

const SEED_BEFORE_BOOKING = `
INSERT INTO performances (id, title, type, status) VALUES ('00000000-0000-7000-8000-0000000000a1', 'fixture-supa-공연', 'PLAY', 'ONGOING');
INSERT INTO classes (id, performance_id, name, status) VALUES ('00000000-0000-7000-8000-0000000000c1', '00000000-0000-7000-8000-0000000000a1', 'fixture-supa-반', 'ACTIVE');
INSERT INTO shows (id, class_id, performance_id, show_date, start_time, status, total_seats)
VALUES ('00000000-0000-7000-8000-0000000000e1', '00000000-0000-7000-8000-0000000000c1', '00000000-0000-7000-8000-0000000000a1', '2026-12-12', '14:00', 'UPCOMING', 100),
       ('00000000-0000-7000-8000-0000000000e2', '00000000-0000-7000-8000-0000000000c1', '00000000-0000-7000-8000-0000000000a1', '2026-12-12', '18:00', 'UPCOMING', NULL);`;

function scenarioBookingUpgrade() {
  const s = '③ 기존 데이터 + V1_0_4';
  console.log(`\n== ${s} (${DB_BOOKING})`);
  createSupabaseLikeDb(DB_BOOKING);
  const before = flyway(DB_BOOKING, ['migrate', '-target=1.0.3']);
  record(s, 'V1_0_3 까지 적용', '성공', before.ok ? '성공' : `실패 — ${firstErrorLine(before.out)}`);
  if (!before.ok) return;
  psqlOrThrow(DB_BOOKING, SEED_BEFORE_BOOKING);
  const after = flyway(DB_BOOKING, ['migrate']);
  record(s, 'V1_0_4 적용', '성공', after.ok ? '성공' : `실패 — ${firstErrorLine(after.out)}`);
  if (!after.ok) return;
  const kept = rows(
    psqlOrThrow(DB_BOOKING, `SELECT count(*), count(*) FILTER (WHERE booking_enabled) FROM shows;`)
  );
  record(s, '기존 회차 유지(전체|예매 켬)', '2|2', kept[0]);
  psqlOrThrow(DB_BOOKING, `DELETE FROM classes WHERE id = '00000000-0000-7000-8000-0000000000c1';`);
  const orphan = rows(psqlOrThrow(DB_BOOKING, `SELECT count(*) FILTER (WHERE class_id IS NULL) FROM shows;`));
  record(s, '반 삭제 뒤 회차가 남음(class_id NULL)', '2', orphan[0]);
  const insertLog = psql(
    DB_BOOKING,
    `INSERT INTO price_tiers (id, performance_id, name, price, visibility)
     VALUES ('00000000-0000-7000-8000-0000000000d1', '00000000-0000-7000-8000-0000000000a1', 'fixture-일반', 10000, 'PUBLIC');
     INSERT INTO reservations (id, performance_id, show_id, code, quantity, amount, booker_name, booker_phone,
       depositor_name, status, source, deposit_due_at, confirmed_at, confirmed_by)
     VALUES ('00000000-0000-7000-8000-0000000000f1', '00000000-0000-7000-8000-0000000000a1', '00000000-0000-7000-8000-0000000000e1',
       '1234', 1, 10000, 'fixture', '01000000000', 'fixture1234', 'CONFIRMED', 'ADMIN', now(), now(), 'MANUAL');
     INSERT INTO reservation_items (reservation_id, tier_id, tier_name, unit_price, quantity, line_amount)
     VALUES ('00000000-0000-7000-8000-0000000000f1', '00000000-0000-7000-8000-0000000000d1', 'fixture-일반', 10000, 1, 10000);
     INSERT INTO admission_logs (reservation_id, delta, admitted_after) VALUES ('00000000-0000-7000-8000-0000000000f1', 1, 1);`,
    RUNTIME_LOGIN
  );
  record(s, '런타임 계정 등급·예매·줄·입장 기록 INSERT', '성공', insertLog.ok ? '성공' : insertLog.err.trim());
  const updateItem = psql(DB_BOOKING, 'UPDATE reservation_items SET unit_price = 1;', RUNTIME_LOGIN);
  record(s, '런타임 계정 예매 줄 UPDATE(가격 스냅숏)', '거부', updateItem.ok ? '성공' : /permission denied/.test(updateItem.err) ? '거부' : updateItem.err.trim());
  const deleteTier = psql(DB_BOOKING, `DELETE FROM price_tiers WHERE id = '00000000-0000-7000-8000-0000000000d1';`, RUNTIME_LOGIN);
  record(s, '예매에 쓰인 등급 DELETE', '거부(FK)', deleteTier.ok ? '성공' : /foreign key/.test(deleteTier.err) ? '거부(FK)' : deleteTier.err.trim());
  const updateLog = psql(DB_BOOKING, 'UPDATE admission_logs SET delta = 2;', RUNTIME_LOGIN);
  record(s, '런타임 계정 입장 기록 UPDATE', '거부', updateLog.ok ? '성공' : /permission denied/.test(updateLog.err) ? '거부' : updateLog.err.trim());
  const deleteLog = psql(DB_BOOKING, 'DELETE FROM admission_logs;', RUNTIME_LOGIN);
  record(s, '런타임 계정 입장 기록 DELETE', '거부', deleteLog.ok ? '성공' : /permission denied/.test(deleteLog.err) ? '거부' : deleteLog.err.trim());
  const deleteShow = psql(DB_BOOKING, `DELETE FROM shows WHERE id = '00000000-0000-7000-8000-0000000000e1';`, RUNTIME_LOGIN);
  record(s, '예매가 있는 회차 DELETE', '거부(FK)', deleteShow.ok ? '성공' : /foreign key/.test(deleteShow.err) ? '거부(FK)' : deleteShow.err.trim());
  // 보유기간 파기 경로: 런타임 계정이 예매를 지우면 입장 기록·예매 줄은 FK CASCADE(소유자 권한)로 함께 지워진다
  const purge = psql(
    DB_BOOKING,
    `DELETE FROM reservations WHERE id = '00000000-0000-7000-8000-0000000000f1';
     SELECT (SELECT count(*) FROM admission_logs) || '|' || (SELECT count(*) FROM reservation_items);`,
    RUNTIME_LOGIN
  );
  record(s, '런타임 계정 예매 DELETE → 입장 기록·줄 CASCADE(남은 수)', '0|0', purge.ok ? rows(purge.out).at(-1) : purge.err.trim());
  record(s, 'check-security.sql 행 수', 0, rows(psqlOrThrow(DB_BOOKING, CHECK_SQL)).length);
}

function scenarioDuplicateShows() {
  const s = '④ 중복 회차 + V1_0_4';
  console.log(`\n== ${s} (${DB_DUPLICATE})`);
  createSupabaseLikeDb(DB_DUPLICATE);
  const before = flyway(DB_DUPLICATE, ['migrate', '-target=1.0.3']);
  record(s, 'V1_0_3 까지 적용', '성공', before.ok ? '성공' : `실패 — ${firstErrorLine(before.out)}`);
  if (!before.ok) return;
  psqlOrThrow(DB_DUPLICATE, SEED_BEFORE_BOOKING);
  psqlOrThrow(
    DB_DUPLICATE,
    `INSERT INTO shows (id, class_id, performance_id, show_date, start_time, status)
     VALUES ('00000000-0000-7000-8000-0000000000e3', '00000000-0000-7000-8000-0000000000c1', '00000000-0000-7000-8000-0000000000a1', '2026-12-12', '14:00', 'UPCOMING');`
  );
  const after = flyway(DB_DUPLICATE, ['migrate']);
  record(s, 'V1_0_4 가 중복 회차로 실패', '실패', after.ok ? '성공' : /V1_0_4 중단/.test(after.out) ? '실패' : firstErrorLine(after.out));
  const version = rows(
    psqlOrThrow(DB_DUPLICATE, `SELECT max(version) FROM flyway_schema_history WHERE success;`)
  );
  record(s, '적용 버전이 1.0.3 에 머묾(롤백)', '1.0.3', version[0]);
  const columns = rows(
    psqlOrThrow(DB_DUPLICATE, `SELECT count(*) FROM information_schema.columns WHERE table_name = 'shows' AND column_name = 'price';`)
  );
  record(s, 'shows.price 컬럼 없음(롤백)', '0', columns[0]);
}

function roleExists(role) {
  return psqlOrThrow('postgres', `SELECT count(*) FROM pg_roles WHERE rolname = '${role}';`).trim() === '1';
}

function main() {
  console.log('Supabase 같은 DB 검증');
  const startRoles = SUPABASE_ROLES.filter(roleExists);
  const createdRoles = [];
  try {
    for (const db of [DB_EMPTY, DB_UPGRADE, DB_BOOKING, DB_DUPLICATE]) dropFixtureDb(db);
    for (const role of SUPABASE_ROLES.filter((r) => !startRoles.includes(r))) {
      psqlOrThrow('postgres', `CREATE ROLE ${role} NOLOGIN;`);
      createdRoles.push(role);
    }
    psql('postgres', `DROP ROLE IF EXISTS ${RUNTIME_LOGIN};`);
    // sam_app 은 첫 마이그레이션이 만들지만 로그인 계정이 먼저 있어야 해서 여기서도 멱등 생성한다(클러스터 공용 역할)
    psqlOrThrow(
      'postgres',
      `DO $$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'sam_app') THEN CREATE ROLE sam_app NOLOGIN; END IF; END $$;
CREATE ROLE ${RUNTIME_LOGIN} LOGIN IN ROLE sam_app;`
    );
    scenarioEmpty();
    scenarioUpgrade();
    scenarioBookingUpgrade();
    scenarioDuplicateShows();
  } catch (error) {
    results.push({ scenario: '실행', item: '예외 없이 끝남', expected: '예', actual: String(error.message ?? error), pass: false });
    console.error(error);
  } finally {
    for (const db of [DB_EMPTY, DB_UPGRADE, DB_BOOKING, DB_DUPLICATE]) dropFixtureDb(db);
    psql('postgres', `DROP ROLE IF EXISTS ${RUNTIME_LOGIN};`);
    for (const role of createdRoles) psql('postgres', `DROP ROLE IF EXISTS ${role};`);
    const left = rows(psqlOrThrow('postgres', `SELECT datname FROM pg_database WHERE datname LIKE '${DB_PREFIX}%';`));
    results.push({ scenario: '정리', item: '일회용 DB 남음', expected: '0', actual: String(left.length), pass: left.length === 0 });
  }
  const failed = results.filter((r) => !r.pass);
  console.log(`\n${results.length}개 중 통과 ${results.length - failed.length} · 실패 ${failed.length}`);
  failed.forEach((r) => console.log(`  실패: [${r.scenario}] ${r.item} — 기대 ${r.expected} · 실제 ${r.actual}`));
  process.exit(failed.length === 0 ? 0 : 1);
}

main();
