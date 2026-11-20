// 권한·RLS 검사 SQL 동기화 테스트 — `pnpm test` (node:test)
// scripts/check-security.sql 과 V1_0_2 끝 검사의 check:begin ~ check:end 가 공백만 빼고 같아야 한다.
import assert from 'node:assert/strict';
import { readdirSync, readFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { describe, it } from 'node:test';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(fileURLToPath(new URL('..', import.meta.url)));

function checkBlock(text) {
  const start = text.indexOf('-- check:begin');
  const end = text.indexOf('-- check:end');
  assert.ok(start >= 0 && end > start, 'check:begin/end 표시가 있어야 한다');
  return text.slice(start, end).replace(/\s+/g, ' ').trim();
}

describe('check-security.sql', () => {
  it('V1_0_2 끝 검사와 같은 식이다', () => {
    const migration = readFileSync(join(ROOT, 'sql/V1_0_2__enable_rls_revoke_anon.sql'), 'utf8');
    const script = readFileSync(join(ROOT, 'scripts/check-security.sql'), 'utf8');
    assert.equal(checkBlock(script), checkBlock(migration));
  });

  it('끝 검사가 있는 모든 마이그레이션(V1_0_4 포함)이 같은 식이다', () => {
    const script = checkBlock(readFileSync(join(ROOT, 'scripts/check-security.sql'), 'utf8'));
    const withCheck = readdirSync(join(ROOT, 'sql'))
      .filter((name) => name.endsWith('.sql'))
      .map((name) => [name, readFileSync(join(ROOT, 'sql', name), 'utf8')])
      .filter(([, text]) => text.includes('-- check:begin'));
    assert.ok(withCheck.some(([name]) => name.startsWith('V1_0_4__')), 'V1_0_4 에 끝 검사가 있어야 한다');
    for (const [name, text] of withCheck) assert.equal(checkBlock(text), script, name);
  });

  it('점검 SQL 은 읽기 전용이다(쓰기·DDL 문 없음)', () => {
    const script = readFileSync(join(ROOT, 'scripts/check-security.sql'), 'utf8')
      .split('\n')
      .filter((line) => !line.trim().startsWith('--'))
      .join('\n');
    // 권한 이름('INSERT' 등)은 문자열로 나오므로 "문장 시작" 키워드만 본다. 문장은 WITH … SELECT 하나뿐이다.
    assert.doesNotMatch(script, /^\s*(INSERT|UPDATE|DELETE|ALTER|DROP|CREATE|GRANT|REVOKE|TRUNCATE|DO)\b/im);
    assert.equal(script.split(';').filter((part) => part.trim() !== '').length, 1);
    assert.match(script.trim(), /^WITH\b/);
  });
});

describe('마이그레이션 규칙', () => {
  it('V1 은 DB enum 타입을 만들지 않는다(VARCHAR + CHECK)', () => {
    const v1 = readFileSync(join(ROOT, 'sql/V1__init_schema.sql'), 'utf8');
    assert.doesNotMatch(v1, /CREATE TYPE/i);
  });

  it('V1 의 모든 앱 테이블이 V1_0_2 RLS 목록에 있다(새 테이블 RLS 누락 방지)', () => {
    const v1 = readFileSync(join(ROOT, 'sql/V1__init_schema.sql'), 'utf8');
    const v102 = readFileSync(join(ROOT, 'sql/V1_0_2__enable_rls_revoke_anon.sql'), 'utf8');
    const tables = [...v1.matchAll(/CREATE TABLE IF NOT EXISTS (\w+)/g)].map((m) => m[1]);
    assert.equal(tables.length, 14);
    for (const table of tables) assert.match(v102, new RegExp(`'${table}'`));
  });
});

describe('V1_0_4 예매 마이그레이션 규칙', () => {
  const v104 = readFileSync(join(ROOT, 'sql/V1_0_4__booking.sql'), 'utf8');

  it('DB enum 타입을 만들지 않는다', () => {
    assert.doesNotMatch(v104, /CREATE TYPE/i);
  });

  it('새 테이블은 모두 같은 파일의 RLS·정책 목록에 있다', () => {
    const tables = [...v104.matchAll(/CREATE TABLE IF NOT EXISTS (\w+)/g)].map((m) => m[1]);
    assert.deepEqual(tables, ['booking_policies', 'price_tiers', 'reservations', 'reservation_items', 'admission_logs']);
    const rlsList = /new_tables CONSTANT text\[\] := ARRAY\[([^\]]+)\]/.exec(v104)?.[1] ?? '';
    for (const table of tables) assert.match(rlsList, new RegExp(`'${table}'`));
  });

  it('입장 기록은 추가만(UPDATE·DELETE 없음), 예매 줄은 UPDATE 없음(가격 스냅숏 보호)', () => {
    assert.match(v104, /GRANT SELECT, INSERT ON admission_logs TO sam_app;/);
    assert.doesNotMatch(v104, /GRANT[^;]*DELETE[^;]*admission_logs/);
    assert.match(v104, /GRANT SELECT, INSERT, DELETE ON reservation_items TO sam_app;/);
    assert.doesNotMatch(v104, /GRANT[^;]*UPDATE[^;]*(admission_logs|reservation_items)/);
  });

  it('가격 등급은 1원 이상이고 회차에는 가격 칸이 없다(사용자 결정 · J-72)', () => {
    assert.match(v104, /CHECK \(price BETWEEN 1 AND 1000000\)/);
    assert.doesNotMatch(v104, /ALTER TABLE shows ADD COLUMN IF NOT EXISTS price/);
  });

  it('flyway_schema_history 를 건드리지 않는다(이력 테이블 교착 — 끝 검사의 제외 조건만 이름이 나온다)', () => {
    const withoutCheck = v104.slice(0, v104.indexOf('-- check:begin')) + v104.slice(v104.indexOf('-- check:end'));
    const code = withoutCheck.split('\n').filter((line) => !line.trim().startsWith('--')).join('\n');
    assert.doesNotMatch(code, /flyway_schema_history/);
  });
});
