-- ----------------------------------------------------------------------
-- V1_0_12(임시 번호 — 배포 때 release-manager 가 다음 빈 번호로 바꾼다, develop J-96):
--   단원 홈페이지 공개 동의일 (U39, 사용자 결정 2026-11-20 ②)
-- 배경: 단원을 홈페이지에 공개(is_visible)하기 전에 본인 동의를 받았는지 대시보드에서 확인하려 한다.
--       동의일은 날짜만 기록한다(시각 불필요 — AGENTS §5 "날짜만 DATE"). 공개를 막지 않고 대시보드가 경고만 한다.
-- 범위: members.public_consent_at DATE NULL 추가. 새 테이블·권한·트리거 변경 없음
--       (sam_app 은 members 에 이미 SELECT·INSERT·UPDATE 가 있다 — V1_0_1).
-- 안전성: 운영 members 에 실데이터가 있다. NULL 허용 컬럼 추가뿐이라 기존 행은 NULL(동의일 미입력)로 남고
--         잠금은 짧다(기본값 없음 → 테이블 재작성 없음). IF NOT EXISTS 로 다시 실행해도 같은 결과.
--         다른 미배포 트랙의 객체와 flyway_schema_history 를 참조하지 않는다(J-96).
-- ----------------------------------------------------------------------

ALTER TABLE members ADD COLUMN IF NOT EXISTS public_consent_at DATE NULL;

COMMENT ON COLUMN members.public_consent_at IS '홈페이지 공개 동의일(KST 날짜). NULL = 미입력. 공개를 막지 않고 대시보드가 경고만 한다(U39)';
