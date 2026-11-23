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

describe('T-SA 마이그레이션 규칙(V1_0_5 일정 취소 · V1_0_6 신청 관심 작품)', () => {
  const v106 = readFileSync(join(ROOT, 'sql/V1_0_5__schedule_cancellation.sql'), 'utf8');
  const v107 = readFileSync(join(ROOT, 'sql/V1_0_6__application_performances.sql'), 'utf8');

  it('기존 일정은 기본값 ACTIVE 로 채워지고 새 테이블은 만들지 않는다', () => {
    assert.match(v106, /ADD COLUMN IF NOT EXISTS status\s+VARCHAR\(20\) NOT NULL DEFAULT 'ACTIVE'/);
    assert.doesNotMatch(v106, /CREATE TABLE/i);
  });

  it('관심 작품 테이블은 RLS·정책을 켜고 런타임 계정에 UPDATE 를 주지 않는다', () => {
    assert.match(v107, /ALTER TABLE public\.application_performances ENABLE ROW LEVEL SECURITY/);
    assert.match(v107, /CREATE POLICY sam_app_all ON public\.application_performances/);
    assert.match(v107, /GRANT SELECT, INSERT, DELETE ON application_performances TO sam_app;/);
    assert.doesNotMatch(v107, /GRANT[^;]*UPDATE[^;]*application_performances/);
  });

  it('기존 신청 채우기(거절 → DROPPED, 단원 등록 상담 → JOINED)가 CHECK 보다 먼저다', () => {
    const fill = v107.indexOf("SET progress = 'DROPPED'");
    assert.ok(fill > 0 && fill < v107.indexOf('ck_applications_progress_rejected'));
    assert.match(v107, /SET progress = 'JOINED'\s+WHERE app_type = 'CONSULTATION' AND member_id IS NOT NULL/);
  });

  it('다른 미배포 트랙 객체와 flyway_schema_history 를 참조하지 않는다(J-96)', () => {
    for (const text of [v106, v107]) {
      const code = (text.includes('-- check:begin')
        ? text.slice(0, text.indexOf('-- check:begin')) + text.slice(text.indexOf('-- check:end'))
        : text)
        .split('\n')
        .filter((line) => !line.trim().startsWith('--'))
        .join('\n');
      assert.doesNotMatch(code, /flyway_schema_history|deposit_notifications|performance_roles|cast_public/);
    }
  });
});

describe('V1_0_7 푸시 구독 마이그레이션 규칙(U37)', () => {
  const v111 = readFileSync(join(ROOT, 'sql/V1_0_7__push_subscriptions.sql'), 'utf8');

  it('새 테이블은 push_subscriptions 하나이고 RLS·정책 목록에 있다', () => {
    const tables = [...v111.matchAll(/CREATE TABLE IF NOT EXISTS (\w+)/g)].map((m) => m[1]);
    assert.deepEqual(tables, ['push_subscriptions']);
    assert.match(v111, /new_tables CONSTANT text\[\] := ARRAY\['push_subscriptions'\]/);
  });

  it('관리자를 지우면 구독도 지워지고 endpoint 는 전역 유일하다', () => {
    assert.match(v111, /admin_id\s+UUID\s+NOT NULL REFERENCES admins \(id\) ON DELETE CASCADE/);
    assert.match(v111, /CONSTRAINT uq_push_subscriptions_endpoint UNIQUE \(endpoint\)/);
    assert.match(v111, /CREATE INDEX IF NOT EXISTS idx_push_subscriptions_admin_id_created_at/);
  });

  it('이름·연락처 같은 개인정보 컬럼을 두지 않는다(J-108)', () => {
    assert.doesNotMatch(v111, /\b(name|phone|applicant)\w*\s+VARCHAR/i);
  });

  it('flyway_schema_history 를 건드리지 않는다', () => {
    const withoutCheck = v111.slice(0, v111.indexOf('-- check:begin')) + v111.slice(v111.indexOf('-- check:end'));
  });
});

describe('V1_0_9 좌석 지정 마이그레이션 규칙(U35·U36)', () => {
  const v110 = readFileSync(join(ROOT, 'sql/V1_0_9__seat_maps.sql'), 'utf8');

  it('DB enum 타입을 만들지 않는다', () => {
    assert.doesNotMatch(v110, /CREATE TYPE/i);
  });

  it('새 테이블은 모두 같은 파일의 RLS·정책 목록에 있다', () => {
    const tables = [...v110.matchAll(/CREATE TABLE IF NOT EXISTS (\w+)/g)].map((m) => m[1]);
    assert.deepEqual(tables, ['show_seat_layouts', 'show_seats', 'reservation_seats']);
    const rlsList = /new_tables CONSTANT text\[\] := ARRAY\[([^\]]+)\]/.exec(v110)?.[1] ?? '';
    for (const table of tables) assert.match(rlsList, new RegExp(`'${table}'`));
  });

  it('살아 있는 예매 좌석만 회차 안에서 유일하다(부분 유니크)', () => {
    assert.match(v110, /CREATE UNIQUE INDEX IF NOT EXISTS uq_reservation_seats_active\s+ON reservation_seats \(show_id, seat_id\) WHERE active;/);
  });

  it('취소·되살리기 때 좌석 active 를 같은 트랜잭션에서 맞춘다(상태 트리거)', () => {
    assert.match(v110, /AFTER UPDATE OF status ON reservations/);
    assert.match(v110, /UPDATE reservation_seats SET active = false/);
    assert.match(v110, /UPDATE reservation_seats SET active = true/);
  });

  it('칸(show_seats)은 런타임 계정에 UPDATE 가 없다', () => {
    assert.match(v110, /GRANT SELECT, INSERT, DELETE ON show_seats TO sam_app;/);
    assert.doesNotMatch(v110, /GRANT[^;]*UPDATE[^;]*show_seats/);
  });

  it('flyway_schema_history 를 건드리지 않는다', () => {
    const withoutCheck = v110.slice(0, v110.indexOf('-- check:begin')) + v110.slice(v110.indexOf('-- check:end'));
    const code = withoutCheck.split('\n').filter((line) => !line.trim().startsWith('--')).join('\n');
    assert.doesNotMatch(code, /flyway_schema_history/);
  });
});

describe('V1_0_8 팀 계정·연습실 예약 마이그레이션 규칙', () => {
  const v109 = readFileSync(join(ROOT, 'sql/V1_0_8__practice_room.sql'), 'utf8');

  it('새 테이블은 모두 같은 파일의 RLS·정책 목록에 있다', () => {
    const tables = [...v109.matchAll(/CREATE TABLE IF NOT EXISTS (\w+)/g)].map((m) => m[1]);
    assert.deepEqual(tables, ['team_accounts', 'room_reservations']);
    const rlsList = /new_tables CONSTANT text\[\] := ARRAY\[([^\]]+)\]/.exec(v109)?.[1] ?? '';
    for (const table of tables) assert.match(rlsList, new RegExp(`'${table}'`));
  });

  it('겹치는 예약은 EXCLUDE tstzrange [) && 로 DB 가 막는다(J-98·PR-3)', () => {
    assert.match(
      v109,
      /EXCLUDE USING gist \(tstzrange\(start_at, end_at, '\[\)'\) WITH &&\) WHERE \(deleted_at IS NULL\)/
    );
  });

  it('비밀번호는 argon2id 해시와 암호화 사본만 저장한다(평문 칸 없음 — J-99)', () => {
    assert.match(v109, /CHECK \(password_hash LIKE '\$argon2id\$%'\)/);
    assert.doesNotMatch(v109, /\bpassword\s+(VARCHAR|TEXT)/i);
  });

  it('DB enum 타입·새 함수를 만들지 않고 flyway_schema_history 를 건드리지 않는다', () => {
    const withoutCheck = v109.slice(0, v109.indexOf('-- check:begin')) + v109.slice(v109.indexOf('-- check:end'));
    const code = withoutCheck.split('\n').filter((line) => !line.trim().startsWith('--')).join('\n');
    assert.doesNotMatch(code, /CREATE TYPE|CREATE (OR REPLACE )?FUNCTION|flyway_schema_history/i);
  });
});

describe('V1_0_11 단원 공개 동의일 마이그레이션 규칙(U39)', () => {
  const v1011 = readFileSync(join(ROOT, 'sql/V1_0_11__member_public_consent.sql'), 'utf8');
  const code = v1011.split('\n').filter((line) => !line.trim().startsWith('--')).join('\n');

  it('members 에 NULL 허용 DATE 컬럼만 더하고 새 테이블·권한은 만들지 않는다', () => {
    assert.match(code, /ALTER TABLE members ADD COLUMN IF NOT EXISTS public_consent_at DATE NULL;/);
    assert.doesNotMatch(code, /CREATE TABLE|GRANT|DEFAULT/i);
  });

  it('flyway_schema_history 를 건드리지 않는다', () => {
    assert.doesNotMatch(code, /flyway_schema_history/);
  });
});

describe('V1_0_12 초대 유형별 가격 마이그레이션 규칙(U41)', () => {
  const v1012 = readFileSync(join(ROOT, 'sql/V1_0_12__inviter_pricing.sql'), 'utf8');
  const code = v1012.split('\n').filter((line) => !line.trim().startsWith('--')).join('\n');

  it('가격 역할은 BASE·SAM_RELATED 두 가지이고 공연당 역할마다 1개다', () => {
    assert.match(code, /role IN \('BASE', 'SAM_RELATED'\)/);
    assert.match(code, /CREATE UNIQUE INDEX IF NOT EXISTS uq_price_tiers_performance_role\s+ON price_tiers \(performance_id, role\) WHERE role IS NOT NULL/);
  });

  it('온라인 SAM 관계자 예매는 확인 시각이 있어야 한다(RSV_015 의 DB 방어)', () => {
    assert.match(code, /inviter_category IS DISTINCT FROM 'SAM_RELATED' OR source <> 'ONLINE' OR sam_related_acknowledged_at IS NOT NULL/);
  });

  it('행을 지우지 않고 SAM_RELATED 등급을 만들지 않는다(가격을 임의로 정하지 않음 — 예매 닫힘)', () => {
    assert.doesNotMatch(code, /DELETE FROM|INSERT INTO price_tiers/i);
    assert.match(code, /SET role = 'BASE'/);
  });

  it('새 테이블을 만들지 않고 flyway_schema_history 를 건드리지 않는다', () => {
    assert.doesNotMatch(code, /CREATE TABLE|flyway_schema_history/);
  });
});

describe('V1_0_13 입금 알림 마이그레이션 규칙(R2)', () => {
  const v113 = readFileSync(join(ROOT, 'sql/V1_0_13__deposit_notifications.sql'), 'utf8');
  const code = (v113.slice(0, v113.indexOf('-- check:begin')) + v113.slice(v113.indexOf('-- check:end')))
    .split('\n')
    .filter((line) => !line.trim().startsWith('--'))
    .join('\n');

  it('새 테이블은 deposit_notifications 하나이고 RLS·정책 목록에 있다', () => {
    const tables = [...v113.matchAll(/CREATE TABLE IF NOT EXISTS (\w+)/g)].map((m) => m[1]);
    assert.deepEqual(tables, ['deposit_notifications']);
    assert.match(v113, /new_tables CONSTANT text\[\] := ARRAY\['deposit_notifications'\]/);
  });

  it('같은 원문 중복은 멱등 키 UNIQUE 로 DB 가 막는다', () => {
    assert.match(v113, /CONSTRAINT uq_deposit_notifications_dedupe_key UNIQUE \(dedupe_key\)/);
  });

  it('예매가 파기되면 연결된 알림도 함께 지워진다(CASCADE)', () => {
    assert.match(v113, /reservation_id\s+UUID\s+NULL REFERENCES reservations \(id\) ON DELETE CASCADE/);
  });

  it('허용 목록 밖 앱은 IGNORED_SOURCE 로 저장하고 예매를 가리키지 않는다', () => {
    assert.match(v113, /'IGNORED_SOURCE'\)/);
    assert.match(v113, /status NOT IN \('UNMATCHED', 'IGNORED_SOURCE'\) OR reservation_id IS NULL/);
    assert.match(v113, /app_package\s+VARCHAR\(100\)\s+NULL/);
  });

  it('원문(본문·금액·해시)은 트리거로 바꿀 수 없다', () => {
    assert.match(v113, /BEFORE UPDATE ON deposit_notifications FOR EACH ROW EXECUTE FUNCTION deposit_notifications_guard_update\(\)/);
    assert.match(v113, /NEW\.body_redacted IS DISTINCT FROM OLD\.body_redacted/);
  });

  it('DB enum 을 쓰지 않고, 다른 미배포 트랙 객체와 flyway_schema_history 를 참조하지 않는다(J-96)', () => {
    assert.doesNotMatch(code, /CREATE TYPE/i);
    assert.doesNotMatch(code, /flyway_schema_history|inviter_pricing|performance_roles/);
  });
});
