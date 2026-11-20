#!/usr/bin/env node
// ----------------------------------------------------------------------
// 권한·RLS 점검 실행기 — `pnpm verify:security [local|development|production]`
// scripts/check-security.sql(읽기 전용 SELECT)을 마이그레이션 계정으로 실행해 위반 행을 출력한다. 0행이면 통과(exit 0).
// - local: 로컬 docker 컨테이너(sam-uijeongbu-db)의 psql 로 실행(trust 인증).
// - development·production: CHECK_DATABASE_URL 환경변수(마이그레이션 계정의 postgres:// 주소 — Supabase 세션 풀러 5432)를
//   postgres 공식 이미지의 psql 로 실행한다. 주소·비밀번호는 인자·로그에 남기지 않는다(-e 로만 전달).
//   또는 Supabase SQL Editor 에 check-security.sql 내용을 붙여 넣고 Run → "No rows returned" 확인.
// ----------------------------------------------------------------------
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

import { ENVIRONMENTS } from './flyway-args.mjs';

const CONTAINER = 'sam-uijeongbu-db';
const PSQL_IMAGE = 'postgres:17.12-alpine';

function fail(message) {
  console.error(`[verify:security] ${message}`);
  process.exit(1);
}

const [env = 'local', ...rest] = process.argv.slice(2);
if (!ENVIRONMENTS.includes(env) || rest.length > 0) {
  fail('사용법: pnpm verify:security [local|development|production]');
}
const sql = readFileSync(resolve(process.cwd(), 'scripts/check-security.sql'), 'utf8');
const psqlArgs = ['-X', '-q', '-v', 'ON_ERROR_STOP=1', '-At', '-F', ' | '];
const run =
  env === 'local'
    ? spawnSync('docker', ['exec', '-i', CONTAINER, 'psql', '-U', 'postgres', '-d', 'sam_uijeongbu', ...psqlArgs], {
        input: sql,
        encoding: 'utf8',
      })
    : (() => {
        if (!process.env.CHECK_DATABASE_URL) {
          fail('CHECK_DATABASE_URL(마이그레이션 계정 주소)이 없습니다.');
        }
        return spawnSync(
          'docker',
          ['run', '--rm', '-i', '-e', 'CHECK_DATABASE_URL', PSQL_IMAGE, 'sh', '-c', `psql "$CHECK_DATABASE_URL" ${psqlArgs.map((a) => `'${a}'`).join(' ')}`],
          { input: sql, encoding: 'utf8' }
        );
      })();

if (run.status !== 0) fail(`psql 실패: ${(run.stderr ?? '').trim()}`);
const rows = (run.stdout ?? '').split('\n').filter((line) => line.length > 0);
if (rows.length > 0) {
  console.error(`[verify:security] ${env} — 위반 ${rows.length}건:\n${rows.join('\n')}`);
  process.exit(1);
}
console.log(`[verify:security] ${env} — 위반 0건(통과)`);
