-- ----------------------------------------------------------------------
-- V1_0_6(임시 번호 — 배포 때 release-manager 가 다음 빈 번호로 바꾼다, 기획 §22.3 · develop J-96):
--   일정 취소 · 사유 · 참관 연동 (U29, FN-48·49, 트랙 T-SA)
-- 배경: 일정은 삭제만 있었다. 연습이 취소돼도 기록을 남기고(홈페이지·대시보드에 "취소 · {사유}"),
--       취소마다 "이 날 참관 신청 받지 않음"을 관리자가 골라 참관 슬롯에서 빼려 한다(사용자 결정 U29, 기획 §17).
--       정본: develop §13.1, 자체 결정 J-66~J-68.
-- 범위: schedules(기존)에 컬럼 4개 + 짝 CHECK 2개 + 부분 인덱스 1개.
--   status            ACTIVE | CANCELLED (기본 ACTIVE)
--   cancel_reason     취소 사유(1~50자, 취소일 때만)
--   cancelled_at      취소 시각(취소일 때만)
--   observation_closed 참관 받지 않음(취소일 때만 NOT NULL — 이벤트·기타 취소는 서버가 false 로 저장, develop §13.4 C-11)
-- 안전성: 운영(Supabase)에는 실데이터 일정이 있다.
--   - 컬럼 추가뿐(NOT NULL 은 기본값 'ACTIVE' 로 기존 행을 채움, 나머지는 NULL) — 기존 행은 모두 ACTIVE·NULL 이 되어
--     짝 CHECK 를 만족한다(기존 행을 지우거나 바꾸지 않는다).
--   - 권한 변경 없음(schedules 는 V1_0_1 에서 이미 SELECT·INSERT·UPDATE). 새 테이블 없음 → 끝 검사 블록 불필요.
--   - 다른 미배포 트랙의 객체를 참조하지 않는다(J-96). 모든 객체는 IF NOT EXISTS / 존재 확인으로 만든다(다시 실행해도 같음).
-- ----------------------------------------------------------------------

ALTER TABLE schedules ADD COLUMN IF NOT EXISTS status             VARCHAR(20) NOT NULL DEFAULT 'ACTIVE';
ALTER TABLE schedules ADD COLUMN IF NOT EXISTS cancel_reason      VARCHAR(50) NULL;
ALTER TABLE schedules ADD COLUMN IF NOT EXISTS cancelled_at       TIMESTAMPTZ NULL;
ALTER TABLE schedules ADD COLUMN IF NOT EXISTS observation_closed BOOLEAN     NULL;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.schedules'::regclass AND conname = 'ck_schedules_status') THEN
        ALTER TABLE schedules ADD CONSTRAINT ck_schedules_status CHECK (status IN ('ACTIVE', 'CANCELLED'));
    END IF;
    -- 상태와 취소 칸의 짝: 활성이면 모두 비고, 취소면 사유(공백 아님)·시각·참관 옵션이 모두 있다
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.schedules'::regclass AND conname = 'ck_schedules_cancellation') THEN
        ALTER TABLE schedules ADD CONSTRAINT ck_schedules_cancellation CHECK (
            (status = 'ACTIVE' AND cancel_reason IS NULL AND cancelled_at IS NULL AND observation_closed IS NULL)
            OR (status = 'CANCELLED' AND char_length(btrim(cancel_reason)) > 0
                AND cancelled_at IS NOT NULL AND observation_closed IS NOT NULL)
        );
    END IF;
END
$$;

-- 상태 필터(관리 목록) · 참관 슬롯 계산에서 취소 일정 찾기
CREATE INDEX IF NOT EXISTS idx_schedules_status_start_at ON schedules (status, start_at) WHERE deleted_at IS NULL;
