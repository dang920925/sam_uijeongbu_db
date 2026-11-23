-- ----------------------------------------------------------------------
-- V1_0_12: 초대한 사람 3종 + 초대 유형별 가격 (U41, v1.3.1 — 기획 develop §22 · §22.1, J-111·J-112·J-113)
-- 배경: 예매의 "초대한 사람"을 필수로 받고(이 작품 배우 · 연출·스태프 관계자 · SAM 관계자 — "없음/모름" 삭제),
--       SAM 관계자는 SAM 가격, 나머지는 기본가로 받는다. 가격은 새 컬럼 대신 price_tiers 의 역할 등급 2개를 재사용한다
--       (예매 줄 · 이름/가격 스냅숏 · 집계가 그대로 — J-111).
-- 범위:
--   ① price_tiers.role VARCHAR(12) NULL — BASE(기본가) · SAM_RELATED(SAM 관계자가). 공연당 역할마다 1개(부분 유니크).
--      역할 등급은 PUBLIC 이다(LINK_ONLY 토큰과 함께 쓰지 않음 — CHECK).
--   ② reservations.inviter_category CHECK 에 SAM_RELATED 추가. 단원 id 는 MEMBER 일 때만(STAFF_RELATED·SAM_RELATED 는 NULL).
--      기존 예매의 NULL(U36 이전 · 초대 없음)은 그대로 둔다 — 새 접수가 NULL 을 쓰지 않게 막는 것은 서버다(DTO 필수).
--      기획의 '옛 값 NONE' 은 운영에 저장된 적이 없어(V1_0_9 CHECK 가 MEMBER·STAFF_RELATED 만 허용) NULL 이 그 자리다.
--   ③ reservations.sam_related_acknowledged_at TIMESTAMPTZ NULL — 온라인 SAM 관계자 예매의 확인 체크 시각(필수 — CHECK).
--      관리자 수동 등록(source ADMIN)은 확인 체크가 없다.
--   ④ 운영 데이터 이전: 역할 등급이 없는 공연마다 **사용 중 PUBLIC 등급 하나(sort_order·id 가 가장 앞)를 BASE 로 지정**한다
--      (첫사랑 '테스트 일반'). SAM_RELATED 는 만들지 않는다 → 그 공연은 관리자가 SAM 관계자가를 넣기 전까지 예매가 닫힌다
--      (NOT_READY — 가격을 임의로 정하지 않는다). LINK_ONLY 등급('테스트 스태프')은 지우지 않고 그대로 둔다(관리 화면에서 숨김).
-- 안전성: NULL 허용 컬럼 추가 · CHECK 교체 · 부분 유니크 추가 · 위 ④ UPDATE 뿐(행 삭제 없음).
--   - 다시 실행해도 같은 결과(IF NOT EXISTS · 제약 존재 확인 · ④는 역할 등급이 이미 있는 공연을 건너뜀).
--   - CHECK 교체 전 위반 행이 있으면 한국어 오류로 롤백한다(데이터를 임의로 고치지 않는다 — AGENTS §6).
--   - 마이그레이션 안에서 flyway_schema_history 는 건드리지 않는다(V1_0_2 교착 교훈).
-- ----------------------------------------------------------------------

-- ── ① price_tiers.role ────────────────────────────────────────────────
ALTER TABLE price_tiers ADD COLUMN IF NOT EXISTS role VARCHAR(12) NULL;
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.price_tiers'::regclass AND conname = 'ck_price_tiers_role') THEN
        ALTER TABLE price_tiers ADD CONSTRAINT ck_price_tiers_role
            CHECK (role IS NULL OR role IN ('BASE', 'SAM_RELATED'));
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.price_tiers'::regclass AND conname = 'ck_price_tiers_role_public') THEN
        ALTER TABLE price_tiers ADD CONSTRAINT ck_price_tiers_role_public
            CHECK (role IS NULL OR visibility = 'PUBLIC');
    END IF;
END
$$;
-- 공연당 역할마다 1개
CREATE UNIQUE INDEX IF NOT EXISTS uq_price_tiers_performance_role
    ON price_tiers (performance_id, role) WHERE role IS NOT NULL;
COMMENT ON COLUMN price_tiers.role IS '초대 유형별 가격 역할(U41) — BASE 기본가 · SAM_RELATED SAM 관계자가. NULL = 예전 등급(관리 화면에서 숨김)';

-- ── ② reservations.inviter_category: SAM_RELATED 추가 ─────────────────
DO $$
DECLARE
    bad_count integer;
BEGIN
    SELECT count(*) INTO bad_count FROM reservations
     WHERE inviter_category IS NOT NULL AND inviter_category NOT IN ('MEMBER', 'STAFF_RELATED', 'SAM_RELATED');
    IF bad_count > 0 THEN
        RAISE EXCEPTION '초대 구분 값이 허용 밖인 예매가 %건 있어 중단합니다(V1_0_12).', bad_count;
    END IF;
    ALTER TABLE reservations DROP CONSTRAINT IF EXISTS ck_reservations_inviter_category;
    ALTER TABLE reservations ADD CONSTRAINT ck_reservations_inviter_category
        CHECK (inviter_category IS NULL OR inviter_category IN ('MEMBER', 'STAFF_RELATED', 'SAM_RELATED'));
    ALTER TABLE reservations DROP CONSTRAINT IF EXISTS ck_reservations_inviter_category_member;
    ALTER TABLE reservations ADD CONSTRAINT ck_reservations_inviter_category_member
        CHECK (inviter_category IS NULL OR inviter_category = 'MEMBER' OR inviter_member_id IS NULL);
END
$$;

-- ── ③ reservations.sam_related_acknowledged_at ───────────────────────
ALTER TABLE reservations ADD COLUMN IF NOT EXISTS sam_related_acknowledged_at TIMESTAMPTZ NULL;
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.reservations'::regclass AND conname = 'ck_reservations_sam_related_ack') THEN
        ALTER TABLE reservations ADD CONSTRAINT ck_reservations_sam_related_ack
            CHECK (inviter_category IS DISTINCT FROM 'SAM_RELATED' OR source <> 'ONLINE' OR sam_related_acknowledged_at IS NOT NULL);
    END IF;
END
$$;
COMMENT ON COLUMN reservations.sam_related_acknowledged_at IS '온라인 SAM 관계자 예매의 확인 체크 시각(U41 — RSV_015). 관리자 수동 등록은 NULL';

-- ── ④ 운영 데이터 이전: 기존 PUBLIC 등급 하나를 BASE 로 ───────────────
UPDATE price_tiers AS t
   SET role = 'BASE'
  FROM (
        SELECT DISTINCT ON (p.performance_id) p.id
          FROM price_tiers AS p
         WHERE p.is_active AND p.visibility = 'PUBLIC'
           AND NOT EXISTS (SELECT 1 FROM price_tiers AS r WHERE r.performance_id = p.performance_id AND r.role IS NOT NULL)
         ORDER BY p.performance_id, p.sort_order, p.id
       ) AS pick
 WHERE t.id = pick.id;
