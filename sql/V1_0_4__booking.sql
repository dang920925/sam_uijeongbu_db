-- ----------------------------------------------------------------------
-- V1_0_4: 예매 1단계 — 회차 관리 · 예매 설정 · 가격 등급 · 예매(등급별 줄) · 입장 기록 · 단원 초대 코드 (U24 1단계, R1)
-- 배경: 극단이 네이버폼 + 계좌이체 입금 대조로 받던 예매를 홈페이지·대시보드로 옮긴다(사용자 결정 U24, 2026-11-20).
--       관리자가 회차(가격·좌석·오픈 시각)와 공연 단위 예매 설정(계좌·1인 최대·입금 기한·환불 규정)을 넣고,
--       관객은 회차를 골라 예매(입금 대기) → 관리자가 입금 확인 → 공연 당일 스태프가 입장 인원을 기록한다.
--       정본: 기획 develop §11.2 "R1 — V1_0_4__booking.sql" + §11.10 가격 등급 확정본(J-72~J-78 — 회차 단일 가격 J-29 를 대체),
--       자체 결정 J-35·J-38~J-43. 사용자 결정(2026-11-20, 지휘자 전달): 0원 등급 없음(등급 가격 1원 이상) — 무료·초대는
--       관리자가 예매를 직접 추가(직접 입력 줄 · 금액 덮어쓰기). 그래서 0원 즉시 확정(FREE)은 두지 않는다.
-- 범위:
--   ① shows(기존): class_id NULL 허용(J-42) + FK 를 ON DELETE SET NULL 로(반을 지워도 예매가 걸린 회차가 사라지지 않게 —
--      기존 CASCADE 는 예매 RESTRICT 와 부딪쳐 반 삭제가 500 이 된다), booking_enabled · updated_at(+트리거) — 가격 칸은 두지 않는다(J-72),
--      UNIQUE(performance_id, show_date, start_time)(SHW_002), sam_app 권한 SELECT → SELECT·INSERT·UPDATE·DELETE(FN-28).
--   ② booking_policies(신규, 공연당 1행 — FN-29). 비어 있는 값이 하나라도 있으면 예매가 열리지 않는다(서버 state 계산).
--      문의처 inquiry_contact 는 선택(열림 조건 아님 — 지휘자 승인 계약 추가, 사용자 원문 "입금자명 … 문의할 수 있도록").
--   ②' price_tiers(신규 — 공연 단위 가격 등급, §11.10). 누구나(PUBLIC) / 링크 전용(LINK_ONLY + 추측 불가 토큰 J-76).
--   ③ reservations(신규 — FN-31~36). 매수·금액은 줄(reservation_items)의 합 — 금액은 관리자가 덮어쓸 수 있다
--      (사용자 결정, amount_overridden 로 표시). 관리자 등록은 연락처·입금자명·입금 기한을 비워 둘 수 있다(온라인은 CHECK 로 필수).
--      좌석 초과 방지는 서버의 회차 단위 advisory 잠금(7002, J-39),
--      입장은 증분 UPDATE + CHECK(admitted_count BETWEEN 0 AND quantity, J-40), 관리 전이는 version 낙관적 잠금(J-40).
--      연락처는 숫자만 저장한다(중복 RSV_004·조회 FN-32·입장 검색이 "숫자만 비교" — 인덱스를 그대로 쓰게).
--      상태와 시각 컬럼의 짝(확정 ↔ confirmed_at·confirmed_by, 취소 ↔ cancelled_at·cancel_reason, 입장 ↔ 확정)을 CHECK 로 묶는다.
--      변경 규칙 트리거: 회차·공연·예매번호·경로·등급 링크 사용·동의 시각·접수 시각은 접수 뒤 바꾸지 않는다(동의 기록 —
--      applications 와 같은 원칙). 회차와 공연이 짝인지도 확인한다. 매수·금액은 관리자 등급 수정(PUT …/items)으로 바뀐다.
--   ③' reservation_items(신규 — 예매의 등급별 줄). 등급 이름·단가 스냅숏(J-77 "같은 등급 줄은 옛 가격"). 런타임 계정은
--      UPDATE 권한이 없다(줄 교체 = 삭제 + 추가). tier_id NULL 은 관리자 '직접 입력' 줄(customLine — 이름(label, 기본
--      '직접 입력') + 매수 + 금액, 단가 없음). 별도 표시 컬럼 대신 tier_id NULL 로 둔 이유는 data-base.md §11.4.
--   ④ admission_logs(신규 — FN-36 처리 기록). 추가만 — UPDATE 는 트리거로 막는다(관리자 행 삭제 시 admin_id SET NULL 만 허용).
--   ⑤ members.invite_code(FN-35, J-38) — 6자, 헷갈리는 0·1·I·O 제외, 유일.
--   ⑥ 새 테이블 3개 RLS + sam_app_all 정책 + GRANT, anon·authenticated·PUBLIC 권한 회수, 끝 검사(V1_0_2 와 같은 식).
--   R2(V1_0_5 deposit_notifications.reservation_id → reservations SET NULL)·R3(V1_0_6 show_role_casts.show_id → shows CASCADE)는
--   이 표들을 FK 로 참조만 한다 — 이 파일의 컬럼·제약을 바꾸지 않고 이어 붙일 수 있게 이름을 고정한다.
-- 안전성: 운영(Supabase)에는 V1~V1_0_3 과 실데이터가 있다(작품 4 · 반 4 · 회차 4 등).
--   - 기존 테이블 변경은 컬럼 추가(NULL 또는 기본값)·NOT NULL 해제·FK 동작 변경·제약 추가뿐 — 기존 행을 지우거나 바꾸지 않는다.
--     booking_enabled 기본 true, updated_at 기본 now(). 기존 회차는 가격 등급·예매 설정이 없어 "준비 중"으로 시작한다.
--   - UNIQUE(performance_id, show_date, start_time) 는 기존 회차에 같은 공연·날짜·시각이 겹치면 만들 수 없다 →
--     만들기 전에 겹침을 세어 있으면 한국어 오류로 이 마이그레이션 전체를 롤백한다(데이터를 임의로 지우지 않는다).
--     운영 적용 전 확인: SELECT performance_id, show_date, start_time, count(*) FROM shows GROUP BY 1,2,3 HAVING count(*) > 1;  -- 0행이어야 함
--   - 모든 객체는 IF NOT EXISTS / CREATE OR REPLACE / DO 블록 존재 확인으로 만든다(다시 실행해도 같은 결과).
--   - 마이그레이션 안에서 flyway_schema_history 는 건드리지 않는다(V1_0_2 교착 교훈).
-- ----------------------------------------------------------------------

-- ── ① shows 변경 ──────────────────────────────────────────────────────
ALTER TABLE shows ALTER COLUMN class_id DROP NOT NULL;

DO $$
BEGIN
    -- 기존 FK(V1 기본 이름 shows_class_id_fkey, ON DELETE CASCADE)를 SET NULL 로 바꾼다
    IF EXISTS (
        SELECT 1 FROM pg_constraint
         WHERE conrelid = 'public.shows'::regclass AND conname = 'shows_class_id_fkey' AND confdeltype = 'c'
    ) THEN
        ALTER TABLE shows DROP CONSTRAINT shows_class_id_fkey;
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conrelid = 'public.shows'::regclass AND conname = 'shows_class_id_fkey'
    ) THEN
        ALTER TABLE shows ADD CONSTRAINT shows_class_id_fkey
            FOREIGN KEY (class_id) REFERENCES classes (id) ON DELETE SET NULL;
    END IF;
END
$$;

ALTER TABLE shows ADD COLUMN IF NOT EXISTS booking_enabled BOOLEAN     NOT NULL DEFAULT true;
ALTER TABLE shows ADD COLUMN IF NOT EXISTS updated_at      TIMESTAMPTZ NOT NULL DEFAULT now();

DO $$
DECLARE
    duplicate_count integer;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.shows'::regclass AND conname = 'ck_shows_total_seats_max') THEN
        ALTER TABLE shows ADD CONSTRAINT ck_shows_total_seats_max CHECK (total_seats IS NULL OR total_seats <= 10000);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.shows'::regclass AND conname = 'ck_shows_time_order') THEN
        ALTER TABLE shows ADD CONSTRAINT ck_shows_time_order CHECK (end_time IS NULL OR end_time > start_time);
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conrelid = 'public.shows'::regclass AND conname = 'uq_shows_performance_date_time'
    ) THEN
        SELECT count(*) INTO duplicate_count
          FROM (SELECT 1 FROM shows GROUP BY performance_id, show_date, start_time HAVING count(*) > 1) d;
        IF duplicate_count > 0 THEN
            RAISE EXCEPTION 'V1_0_4 중단 — 같은 공연·날짜·시작 시각의 회차가 %묶음 있다. 중복 회차를 정리한 뒤 다시 적용한다', duplicate_count;
        END IF;
        ALTER TABLE shows ADD CONSTRAINT uq_shows_performance_date_time UNIQUE (performance_id, show_date, start_time);
    END IF;
END
$$;
-- (performance_id, show_date, start_time) 유니크 인덱스가 idx_shows_performance_id(performance_id, show_date) 를 대신할 수 있지만,
-- V1 객체는 그대로 둔다(불변 원칙 — 지우면 이 파일만 다시 읽는 사람이 헷갈린다).

CREATE OR REPLACE TRIGGER trg_shows_updated_at
    BEFORE UPDATE ON shows FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ── ② booking_policies: 공연 단위 예매 설정 (FN-29) ─────────────────────
CREATE TABLE IF NOT EXISTS booking_policies (
    performance_id          UUID          NOT NULL PRIMARY KEY REFERENCES performances (id) ON DELETE CASCADE,
    deposit_bank            VARCHAR(30)   NULL,
    deposit_account_number  VARCHAR(30)   NULL,
    deposit_account_holder  VARCHAR(30)   NULL,
    max_tickets_per_booking SMALLINT      NULL,
    deposit_deadline_hours  SMALLINT      NULL,
    refund_policy_text      VARCHAR(2000) NULL,
    -- 문의처(선택 — 입금자명을 잘못 적은 관객이 연락할 곳, 지휘자 승인 계약 추가 2026-11-20). 예매가 열리는 조건은 아니다
    inquiry_contact         VARCHAR(200)  NULL,
    created_at              TIMESTAMPTZ   NOT NULL DEFAULT now(),
    updated_at              TIMESTAMPTZ   NOT NULL DEFAULT now(),
    CONSTRAINT ck_booking_policies_account_number
        CHECK (deposit_account_number IS NULL OR deposit_account_number ~ '^[0-9-]{6,30}$'),
    CONSTRAINT ck_booking_policies_bank_not_blank
        CHECK (deposit_bank IS NULL OR char_length(btrim(deposit_bank)) > 0),
    CONSTRAINT ck_booking_policies_holder_not_blank
        CHECK (deposit_account_holder IS NULL OR char_length(btrim(deposit_account_holder)) > 0),
    CONSTRAINT ck_booking_policies_max_tickets
        CHECK (max_tickets_per_booking IS NULL OR max_tickets_per_booking BETWEEN 1 AND 20),
    CONSTRAINT ck_booking_policies_deadline_hours
        CHECK (deposit_deadline_hours IS NULL OR deposit_deadline_hours BETWEEN 1 AND 168),
    CONSTRAINT ck_booking_policies_refund_not_blank
        CHECK (refund_policy_text IS NULL OR char_length(btrim(refund_policy_text)) > 0),
    -- URL 은 https 만(가이드 A17.2 — javascript:·data:·http: 등 다른 스킴 거부. 'https:' 는 'http:' 와 겹치지 않는다)
    CONSTRAINT ck_booking_policies_inquiry_contact
        CHECK (inquiry_contact IS NULL
               OR (char_length(btrim(inquiry_contact)) > 0
                   AND inquiry_contact !~* '(http|javascript|data|vbscript|file|ftp)\s*:'))
);
CREATE OR REPLACE TRIGGER trg_booking_policies_updated_at
    BEFORE UPDATE ON booking_policies FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ── ②' price_tiers: 공연 단위 가격 등급 (develop §11.10) ──────────────
-- 가격은 1원 이상(사용자 결정 — 0원 등급 없음, 무료·초대는 관리자 직접 추가). 링크 전용은 토큰이 있어야만 고를 수 있다.
CREATE TABLE IF NOT EXISTS price_tiers (
    id             UUID        NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    performance_id UUID        NOT NULL REFERENCES performances (id) ON DELETE CASCADE,
    name           VARCHAR(30) NOT NULL,
    price          INTEGER     NOT NULL,
    visibility     VARCHAR(10) NOT NULL,
    link_token     VARCHAR(32) NULL,
    sort_order     SMALLINT    NOT NULL DEFAULT 0,
    is_active      BOOLEAN     NOT NULL DEFAULT true,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_price_tiers_performance_name UNIQUE (performance_id, name),
    CONSTRAINT uq_price_tiers_link_token UNIQUE (link_token),
    CONSTRAINT ck_price_tiers_name_not_blank CHECK (char_length(btrim(name)) > 0),
    CONSTRAINT ck_price_tiers_price CHECK (price BETWEEN 1 AND 1000000),
    CONSTRAINT ck_price_tiers_visibility CHECK (visibility IN ('PUBLIC', 'LINK_ONLY')),
    -- 링크 전용 ↔ 토큰(128비트 무작위 base64url 22자 — J-76)
    CONSTRAINT ck_price_tiers_link_token
        CHECK ((visibility = 'LINK_ONLY') = (link_token IS NOT NULL)),
    CONSTRAINT ck_price_tiers_link_token_format
        CHECK (link_token IS NULL OR link_token ~ '^[A-Za-z0-9_-]{22,32}$'),
    CONSTRAINT ck_price_tiers_sort_order CHECK (sort_order BETWEEN 0 AND 999)
);
-- 공연별 등급 목록(정렬) — performance_id FK 인덱스를 겸한다
CREATE INDEX IF NOT EXISTS idx_price_tiers_performance_sort ON price_tiers (performance_id, sort_order);
CREATE OR REPLACE TRIGGER trg_price_tiers_updated_at
    BEFORE UPDATE ON price_tiers FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ── ③ reservations: 예매 (FN-31~36) ───────────────────────────────────
-- 소프트 삭제 없음: 보유기간(공연 마지막 회차일 + BOOKING_RETENTION_DAYS, 기본 90일 — J-36)이 지나면 일일 작업이 영구 삭제한다.
CREATE TABLE IF NOT EXISTS reservations (
    id                 UUID         NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    performance_id     UUID         NOT NULL REFERENCES performances (id),
    show_id            UUID         NOT NULL REFERENCES shows (id) ON DELETE RESTRICT,
    code               CHAR(4)      NOT NULL,
    quantity           SMALLINT     NOT NULL,
    amount             INTEGER      NOT NULL,
    booker_name        VARCHAR(50)  NOT NULL,
    booker_phone       VARCHAR(20)  NULL,
    depositor_name     VARCHAR(20)  NULL,
    inviter_member_id  UUID         NULL REFERENCES members (id) ON DELETE SET NULL,
    inviter_note       VARCHAR(50)  NULL,
    status             VARCHAR(20)  NOT NULL,
    source             VARCHAR(10)  NOT NULL,
    deposit_due_at     TIMESTAMPTZ  NULL,
    confirmed_at       TIMESTAMPTZ  NULL,
    confirmed_by       VARCHAR(10)  NULL,
    confirmed_admin_id UUID         NULL REFERENCES admins (id) ON DELETE SET NULL,
    cancelled_at       TIMESTAMPTZ  NULL,
    cancel_reason      VARCHAR(20)  NULL,
    memo               VARCHAR(500) NULL,
    admitted_count     SMALLINT     NOT NULL DEFAULT 0,
    first_admitted_at  TIMESTAMPTZ  NULL,
    privacy_agreed_at  TIMESTAMPTZ  NULL,
    refund_agreed_at   TIMESTAMPTZ  NULL,
    tier_token_used    BOOLEAN      NOT NULL DEFAULT false,
    amount_overridden  BOOLEAN      NOT NULL DEFAULT false,
    version            INTEGER      NOT NULL DEFAULT 1,
    created_at         TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at         TIMESTAMPTZ  NOT NULL DEFAULT now(),
    -- 예매번호는 공연 안에서 유일(취소 포함 — 번호 재사용 혼동 방지, J-35). 이 유니크 인덱스가 performance_id FK 인덱스를 겸한다
    CONSTRAINT uq_reservations_performance_code UNIQUE (performance_id, code),
    CONSTRAINT ck_reservations_code CHECK (code ~ '^[0-9]{4}$'),
    -- 매수 = 줄 매수 합(서버가 같은 트랜잭션에서 맞춘다), 금액 = 줄 금액 합 또는 관리자 덮어쓰기
    CONSTRAINT ck_reservations_quantity CHECK (quantity BETWEEN 1 AND 20),
    CONSTRAINT ck_reservations_amount CHECK (amount BETWEEN 0 AND 20000000),
    CONSTRAINT ck_reservations_booker_name_not_blank CHECK (char_length(btrim(booker_name)) > 0),
    -- 연락처는 숫자만(서버가 PHONE_NUMBER_PATTERN 검증 뒤 하이픈을 뺀다)
    CONSTRAINT ck_reservations_booker_phone CHECK (booker_phone IS NULL OR booker_phone ~ '^[0-9]{9,13}$'),
    CONSTRAINT ck_reservations_depositor_name_not_blank
        CHECK (depositor_name IS NULL OR char_length(btrim(depositor_name)) > 0),
    -- 온라인 예매는 연락처·입금자명·입금 기한이 반드시 있다. 관리자 등록(초대·현장)은 비워 둘 수 있다(§11.10 보충)
    CONSTRAINT ck_reservations_online_contact
        CHECK (source <> 'ONLINE' OR (booker_phone IS NOT NULL AND depositor_name IS NOT NULL AND deposit_due_at IS NOT NULL)),
    CONSTRAINT ck_reservations_status CHECK (status IN ('PENDING', 'CONFIRMED', 'CANCELLED')),
    CONSTRAINT ck_reservations_source CHECK (source IN ('ONLINE', 'ADMIN')),
    CONSTRAINT ck_reservations_confirmed_by CHECK (confirmed_by IS NULL OR confirmed_by IN ('MANUAL', 'AUTO')),
    CONSTRAINT ck_reservations_cancel_reason
        CHECK (cancel_reason IS NULL OR cancel_reason IN ('BOOKER_REQUEST', 'ADMIN', 'DEADLINE_PASSED')),
    CONSTRAINT ck_reservations_memo_length CHECK (memo IS NULL OR char_length(memo) <= 500),
    -- 확정 상태 ↔ 확정 시각·방법이 함께 있다(확정 취소·되살리기는 둘 다 지운다)
    CONSTRAINT ck_reservations_confirmed_fields
        CHECK ((status = 'CONFIRMED') = (confirmed_at IS NOT NULL AND confirmed_by IS NOT NULL)),
    CONSTRAINT ck_reservations_confirmed_admin
        CHECK (confirmed_admin_id IS NULL OR status = 'CONFIRMED'),
    -- 취소 상태 ↔ 취소 시각·사유가 함께 있다
    CONSTRAINT ck_reservations_cancelled_fields
        CHECK ((status = 'CANCELLED') = (cancelled_at IS NOT NULL AND cancel_reason IS NOT NULL)),
    -- 입장 인원은 0 ~ 매수, 입장이 있으면 확정 상태(취소·확정 취소는 입장을 먼저 되돌려야 한다 — RSV_009)
    CONSTRAINT ck_reservations_admitted_count CHECK (admitted_count BETWEEN 0 AND quantity),
    CONSTRAINT ck_reservations_admitted_requires_confirmed CHECK (admitted_count = 0 OR status = 'CONFIRMED'),
    -- 온라인 예매는 두 동의 시각이 반드시 있다(FN-31 RSV_005·RSV_006)
    CONSTRAINT ck_reservations_online_agreements
        CHECK (source <> 'ONLINE' OR (privacy_agreed_at IS NOT NULL AND refund_agreed_at IS NOT NULL)),
    CONSTRAINT ck_reservations_version CHECK (version >= 1)
);
-- 회차별 상태 합계(남은 좌석·집계·입장 명단) — show_id FK 인덱스를 겸한다
CREATE INDEX IF NOT EXISTS idx_reservations_show_status ON reservations (show_id, status);
-- 예매 확인(FN-32)·같은 연락처 중복(RSV_004)
CREATE INDEX IF NOT EXISTS idx_reservations_booker_phone ON reservations (booker_phone);
-- 초대 단원 FK · 단원별 집계
CREATE INDEX IF NOT EXISTS idx_reservations_inviter_member_id ON reservations (inviter_member_id);
-- 확정 관리자 FK(관리자 행 삭제 시 SET NULL)
CREATE INDEX IF NOT EXISTS idx_reservations_confirmed_admin_id ON reservations (confirmed_admin_id);
-- 기한 지난 입금 대기(목록 필터·일괄 취소 — J-32)
CREATE INDEX IF NOT EXISTS idx_reservations_status_deposit_due_at ON reservations (status, deposit_due_at);
CREATE OR REPLACE TRIGGER trg_reservations_updated_at
    BEFORE UPDATE ON reservations FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- 예매 변경 규칙(데이터 변경 정책 — data-base.md):
--   INSERT: 회차가 그 공연의 회차여야 한다(공연 id 를 따로 저장하므로 짝이 어긋나지 않게).
--   UPDATE: 접수 내용 중 회차·공연·예매번호·경로·등급 링크 사용·동의 시각·접수 시각은 바꾸지 않는다.
--           상태·확정/취소 기록·메모·입장 인원·초대 단원·버전·입금 기한·매수·금액(관리자 등급 수정)은 바꿀 수 있다.
--   삭제(보유기간 파기)는 막지 않는다.
CREATE OR REPLACE FUNCTION reservations_guard_write() RETURNS trigger
    LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NOT EXISTS (SELECT 1 FROM shows s WHERE s.id = NEW.show_id AND s.performance_id = NEW.performance_id) THEN
            RAISE EXCEPTION '회차와 공연이 맞지 않는다(reservations show %, performance %)', NEW.show_id, NEW.performance_id
                USING ERRCODE = 'check_violation';
        END IF;
        RETURN NEW;
    END IF;
    IF (NEW.performance_id, NEW.show_id, NEW.code, NEW.source, NEW.tier_token_used,
        NEW.privacy_agreed_at, NEW.refund_agreed_at, NEW.created_at)
       IS DISTINCT FROM
       (OLD.performance_id, OLD.show_id, OLD.code, OLD.source, OLD.tier_token_used,
        OLD.privacy_agreed_at, OLD.refund_agreed_at, OLD.created_at) THEN
        RAISE EXCEPTION '예매 접수 내용은 바꿀 수 없다(reservations %)', OLD.id
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END
$$;
CREATE OR REPLACE TRIGGER trg_reservations_guard_write
    BEFORE INSERT OR UPDATE ON reservations FOR EACH ROW EXECUTE FUNCTION reservations_guard_write();

-- ── ③' reservation_items: 예매의 등급별 줄 (develop §11.10) ───────────
-- 등급 줄: tier_id·단가 스냅숏 있음, 금액 = 단가 × 매수. 직접 입력 줄(관리자 — 사용자 결정): tier_id·단가 없음, 금액 직접.
-- 등급 이름도 스냅숏(등급 이름을 바꿔도 예매 당시 이름 — 입장 화면 "스태프 1").
CREATE TABLE IF NOT EXISTS reservation_items (
    id             UUID        NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    reservation_id UUID        NOT NULL REFERENCES reservations (id) ON DELETE CASCADE,
    tier_id        UUID        NULL REFERENCES price_tiers (id) ON DELETE RESTRICT,
    tier_name      VARCHAR(30) NOT NULL,
    unit_price     INTEGER     NULL,
    quantity       SMALLINT    NOT NULL,
    line_amount    INTEGER     NOT NULL,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    -- 같은 예매에 같은 등급 줄은 하나(직접 입력 줄 tier_id NULL 은 서버가 1줄로 제한)
    CONSTRAINT uq_reservation_items_reservation_tier UNIQUE (reservation_id, tier_id),
    CONSTRAINT ck_reservation_items_tier_name_not_blank CHECK (char_length(btrim(tier_name)) > 0),
    CONSTRAINT ck_reservation_items_quantity CHECK (quantity BETWEEN 1 AND 20),
    CONSTRAINT ck_reservation_items_line_amount CHECK (line_amount BETWEEN 0 AND 20000000),
    CONSTRAINT ck_reservation_items_kind CHECK (
        (tier_id IS NOT NULL AND unit_price IS NOT NULL AND unit_price >= 1 AND line_amount = unit_price * quantity)
        OR (tier_id IS NULL AND unit_price IS NULL)
    )
);
-- 등급 FK(등급 삭제 시 RESTRICT 확인 · 사용량 집계)
CREATE INDEX IF NOT EXISTS idx_reservation_items_tier_id ON reservation_items (tier_id);

-- ── ④ admission_logs: 입장 처리 기록 (FN-36) — 추가만 ─────────────────
CREATE TABLE IF NOT EXISTS admission_logs (
    id             UUID        NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    reservation_id UUID        NOT NULL REFERENCES reservations (id) ON DELETE CASCADE,
    delta          SMALLINT    NOT NULL,
    admitted_after SMALLINT    NOT NULL,
    admin_id       UUID        NULL REFERENCES admins (id) ON DELETE SET NULL,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT ck_admission_logs_delta CHECK (delta <> 0 AND delta BETWEEN -20 AND 20),
    CONSTRAINT ck_admission_logs_admitted_after CHECK (admitted_after BETWEEN 0 AND 20)
);
-- 예매별 기록(시간순) — reservation_id FK 인덱스를 겸한다
CREATE INDEX IF NOT EXISTS idx_admission_logs_reservation_created_at ON admission_logs (reservation_id, created_at);
CREATE INDEX IF NOT EXISTS idx_admission_logs_admin_id ON admission_logs (admin_id);

-- 기록은 고치지 않는다 — 관리자 행이 지워질 때의 FK SET NULL(admin_id → NULL)만 허용한다
CREATE OR REPLACE FUNCTION admission_logs_guard_update() RETURNS trigger
    LANGUAGE plpgsql AS $$
BEGIN
    IF (NEW.id, NEW.reservation_id, NEW.delta, NEW.admitted_after, NEW.created_at)
       IS DISTINCT FROM
       (OLD.id, OLD.reservation_id, OLD.delta, OLD.admitted_after, OLD.created_at)
       OR (NEW.admin_id IS NOT NULL AND NEW.admin_id IS DISTINCT FROM OLD.admin_id) THEN
        RAISE EXCEPTION '입장 기록은 바꿀 수 없다(admission_logs %)', OLD.id
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END
$$;
CREATE OR REPLACE TRIGGER trg_admission_logs_guard_update
    BEFORE UPDATE ON admission_logs FOR EACH ROW EXECUTE FUNCTION admission_logs_guard_update();

-- ── ⑤ members.invite_code: 단원 초대 코드 (FN-35, J-38) ─────────────────
ALTER TABLE members ADD COLUMN IF NOT EXISTS invite_code VARCHAR(6) NULL;
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.members'::regclass AND conname = 'ck_members_invite_code') THEN
        ALTER TABLE members ADD CONSTRAINT ck_members_invite_code
            CHECK (invite_code IS NULL OR invite_code ~ '^[A-HJ-NP-Z2-9]{6}$');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.members'::regclass AND conname = 'uq_members_invite_code') THEN
        ALTER TABLE members ADD CONSTRAINT uq_members_invite_code UNIQUE (invite_code);
    END IF;
END
$$;

-- ── ⑥ 권한 · RLS ─────────────────────────────────────────────────────
-- 회차: 관리 UI(FN-28)가 생겨 읽기 → 읽기·쓰기·삭제(예매가 있으면 FK RESTRICT + 서버 SHW_004)
GRANT SELECT, INSERT, UPDATE, DELETE ON shows TO sam_app;
-- 예매 설정·예매: 읽기·쓰기·삭제(예매는 보유기간 파기)
GRANT SELECT, INSERT, UPDATE, DELETE ON booking_policies, price_tiers, reservations TO sam_app;
-- 예매 줄: 교체 = 삭제 + 추가(UPDATE 없음 — 가격 스냅숏을 고치는 경로를 두지 않는다)
GRANT SELECT, INSERT, DELETE ON reservation_items TO sam_app;
-- 입장 기록: 추가만(UPDATE 없음 — 최소 권한, 트리거와 이중 방어). DELETE 는 파기(예매 CASCADE)용
GRANT SELECT, INSERT, DELETE ON admission_logs TO sam_app;

DO $$
DECLARE
    new_tables CONSTANT text[] := ARRAY['booking_policies', 'price_tiers', 'reservations', 'reservation_items', 'admission_logs'];
    t text;
    r text;
BEGIN
    FOREACH t IN ARRAY new_tables LOOP
        EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
        IF NOT EXISTS (
            SELECT 1 FROM pg_policies
             WHERE schemaname = 'public' AND tablename = t AND policyname = 'sam_app_all'
        ) THEN
            EXECUTE format(
                'CREATE POLICY sam_app_all ON public.%I AS PERMISSIVE FOR ALL TO sam_app USING (true) WITH CHECK (true)',
                t
            );
        END IF;
        -- Supabase 기본 권한이 새 테이블에 붙었을 수 있다 — 테이블 단위로 다시 회수한다(V1_0_2 ③ 과 같은 대상)
        EXECUTE format('REVOKE ALL ON public.%I FROM PUBLIC', t);
        FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
            IF to_regrole(r) IS NOT NULL THEN
                EXECUTE format('REVOKE ALL ON public.%I FROM %I', t, r);
            END IF;
        END LOOP;
    END LOOP;

    -- 새 트리거 함수의 EXECUTE(트리거는 실행 권한을 보지 않으므로 회수해도 동작은 같다)
    REVOKE ALL ON FUNCTION reservations_guard_write() FROM PUBLIC;
    REVOKE ALL ON FUNCTION admission_logs_guard_update() FROM PUBLIC;
    FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
        IF to_regrole(r) IS NOT NULL THEN
            EXECUTE format('REVOKE ALL ON FUNCTION public.reservations_guard_write() FROM %I', r);
            EXECUTE format('REVOKE ALL ON FUNCTION public.admission_logs_guard_update() FROM %I', r);
        END IF;
    END LOOP;
END
$$;

-- ── ⑦ 끝 검사 — 위반 0건이 아니면 롤백 ─────────────────────────────────
-- 아래 begin·end 표시 사이는 scripts/check-security.sql 과 같은 식이어야 한다
-- (db 테스트 scripts/check-security.test.mjs 가 check:begin 이 있는 모든 마이그레이션을 공백 정규화해 비교한다).
DO $$
DECLARE
    violation_count integer;
    violation_list  text;
BEGIN
    WITH
-- check:begin
    target_roles AS (
        SELECT rolname::text AS role_name FROM pg_roles WHERE rolname IN ('anon', 'authenticated')
        UNION ALL SELECT 'public'
    ),
    relation_privileges AS (
        SELECT 'relation' AS kind, c.relname::text AS object_name, t.role_name, p.privilege
          FROM pg_class c
          CROSS JOIN target_roles t
          CROSS JOIN unnest(ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER']) AS p(privilege)
         WHERE c.relnamespace = 'public'::regnamespace
           AND c.relkind IN ('r', 'p', 'v', 'm', 'f')
           AND (has_table_privilege(t.role_name, c.oid, p.privilege)
                OR (p.privilege IN ('SELECT', 'INSERT', 'UPDATE', 'REFERENCES')
                    AND has_any_column_privilege(t.role_name, c.oid, p.privilege)))
    ),
    sequence_privileges AS (
        SELECT 'sequence', c.relname::text, t.role_name, p.privilege
          FROM pg_class c
          CROSS JOIN target_roles t
          CROSS JOIN unnest(ARRAY['USAGE', 'SELECT', 'UPDATE']) AS p(privilege)
         WHERE c.relnamespace = 'public'::regnamespace AND c.relkind = 'S'
           AND has_sequence_privilege(t.role_name, c.oid, p.privilege)
    ),
    function_privileges AS (
        SELECT 'function', p.oid::regprocedure::text, t.role_name, 'EXECUTE'
          FROM pg_proc p
          CROSS JOIN target_roles t
         WHERE p.pronamespace = 'public'::regnamespace
           AND has_function_privilege(t.role_name, p.oid, 'EXECUTE')
    ),
    schema_privileges AS (
        SELECT 'schema', 'public', g.rolname::text, a.privilege_type
          FROM pg_namespace n
          CROSS JOIN LATERAL aclexplode(n.nspacl) a
          JOIN pg_roles g ON g.oid = a.grantee
         WHERE n.nspname = 'public'
           AND g.rolname IN ('anon', 'authenticated')
        UNION
        SELECT 'schema', 'public', t.role_name, 'CREATE'
          FROM target_roles t
         WHERE has_schema_privilege(t.role_name, 'public', 'CREATE')
    ),
    default_privileges AS (
        SELECT 'default_acl', pg_get_userbyid(d.defaclrole) || ':' || d.defaclobjtype::text, g.rolname::text, a.privilege_type
          FROM pg_default_acl d
          CROSS JOIN LATERAL aclexplode(d.defaclacl) a
          JOIN pg_roles g ON g.oid = a.grantee
         WHERE (d.defaclnamespace = 'public'::regnamespace OR d.defaclnamespace = 0)
           AND g.rolname IN ('anon', 'authenticated')
           AND (d.defaclrole = current_user::regrole
                OR d.defaclrole IN (SELECT c.relowner FROM pg_class c WHERE c.relnamespace = 'public'::regnamespace))
    ),
    rls_disabled AS (
        SELECT 'rls_disabled', c.relname::text, '-', 'ROW LEVEL SECURITY'
          FROM pg_class c
         WHERE c.relnamespace = 'public'::regnamespace
           AND c.relkind IN ('r', 'p')
           AND c.relname <> 'flyway_schema_history'
           AND NOT c.relrowsecurity
    ),
    policy_to_supabase_roles AS (
        SELECT 'policy', p.tablename::text || '.' || p.policyname::text, r.role_name::text, p.cmd::text
          FROM pg_policies p
          CROSS JOIN LATERAL unnest(p.roles) AS r(role_name)
         WHERE p.schemaname = 'public'
           AND r.role_name IN ('anon', 'authenticated', 'public')
    ),
    violations AS (
        SELECT * FROM relation_privileges
        UNION ALL SELECT * FROM sequence_privileges
        UNION ALL SELECT * FROM function_privileges
        UNION ALL SELECT * FROM schema_privileges
        UNION ALL SELECT * FROM default_privileges
        UNION ALL SELECT * FROM rls_disabled
        UNION ALL SELECT * FROM policy_to_supabase_roles
    )
-- check:end
    SELECT count(*), string_agg(kind || ':' || object_name || ':' || role_name || ':' || privilege, ', ')
      INTO violation_count, violation_list
      FROM violations;

    IF violation_count > 0 THEN
        RAISE EXCEPTION 'V1_0_4 끝 검사 실패 — 권한·RLS 위반 %건: %', violation_count, violation_list;
    END IF;
END
$$;
