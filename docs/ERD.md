# ERD — SAM 의정부

> 최종 반영: **V1_0_7(임시 번호, 트랙 T-SA)** (2026-11-20 — U29 일정 취소 · U31 신청 관심 작품·연락·진행). V1_0_4 까지가 R1. 정본은 `sql/` 의 Flyway 마이그레이션이고, 서버 `prisma/schema.prisma` 는 `prisma db pull` 파생물이다.
> 열거값은 VARCHAR + CHECK(UPPER_SNAKE), 시각은 TIMESTAMPTZ, 관리 콘텐츠는 소프트 삭제(`deleted_at`), id 는 UUID(서버가 v7 생성).

```mermaid
erDiagram
    performances ||--o{ performance_detail_images : "상세 이미지(순서)"
    performances ||--o{ classes : "운영반"
    performances ||--o{ shows : "회차"
    performances |o--o{ schedules : "연결 공연(SET NULL)"
    performances |o--o{ applications : "참관 공연(SET NULL)"
    classes ||--o{ class_days : "요일(0=일~6=토)"
    classes |o--o{ shows : "회차(V1_0_4 부터 반 선택 · SET NULL)"
    classes |o--o{ schedules : "연결 반(SET NULL)"
    members ||--o| actor_profiles : "배우 프로필"
    actor_profiles ||--o{ actor_filmographies : "출연작(순서)"
    members |o--o{ applications : "단원으로 등록(D6, SET NULL)"
    performances ||--o| booking_policies : "예매 설정(공연당 1행, CASCADE)"
    performances ||--o{ reservations : "예매(공연 단위 예매번호)"
    shows ||--o{ reservations : "예매(RESTRICT — 예매 있는 회차 삭제 불가)"
    members |o--o{ reservations : "초대 단원(SET NULL)"
    admins |o--o{ reservations : "확정 관리자(SET NULL)"
    reservations ||--o{ admission_logs : "입장 기록(추가만, CASCADE)"
    performances ||--o{ price_tiers : "가격 등급(CASCADE)"
    reservations ||--|{ reservation_items : "등급별 줄(CASCADE)"
    price_tiers |o--o{ reservation_items : "등급(RESTRICT — 직접 입력 줄은 NULL)"
    admins |o--o{ admission_logs : "처리 관리자(SET NULL)"
    applications ||--o{ application_performances : "관심·희망 작품(V1_0_7, CASCADE)"
    performances ||--o{ application_performances : "관심 대상(CASCADE)"

    admins { uuid id PK; varchar username UK; varchar password_hash "argon2id PHC"; int consecutive_failures; timestamptz locked_until; timestamptz hard_locked_at; int session_version }
    performances { uuid id PK; varchar title; varchar type "MUSICAL|PLAY|SEMINAR|ETC"; varchar status "UPCOMING|ONGOING|ENDED"; text description; varchar poster_image_url; bool is_visible; timestamptz deleted_at }
    performance_detail_images { uuid id PK; uuid performance_id FK; varchar image_url; smallint sort_order }
    classes { uuid id PK; uuid performance_id FK; varchar name; time start_time; time end_time; date deadline; varchar location; varchar status "ACTIVE|INACTIVE" }
    class_days { uuid class_id PK; smallint day_of_week PK }
    shows { uuid id PK; uuid class_id FK "NULL 허용(V1_0_4)"; uuid performance_id FK; date show_date; time start_time; varchar venue; varchar status "UPCOMING|BOOKING_OPEN|COMPLETED"; int total_seats; bool booking_enabled "V1_0_4"; timestamptz booking_open_at }
    members { uuid id PK; varchar name; varchar type "GENERAL|ACTOR"; varchar phone; bool is_visible; date joined_at; varchar invite_code UK "V1_0_4"; timestamptz deleted_at }
    booking_policies { uuid performance_id PK; varchar deposit_bank; varchar deposit_account_number; varchar deposit_account_holder; smallint max_tickets_per_booking "1~20"; smallint deposit_deadline_hours "1~168"; varchar refund_policy_text; varchar inquiry_contact "선택, URL 은 https" }
    reservations { uuid id PK; uuid performance_id FK; uuid show_id FK; char code "4자리, 공연 안 UK"; smallint quantity "줄 합"; int amount "줄 합 또는 관리자 덮어쓰기"; bool tier_token_used; varchar booker_name; varchar booker_phone "숫자만"; varchar depositor_name; uuid inviter_member_id FK; varchar inviter_note; varchar status "PENDING|CONFIRMED|CANCELLED"; varchar source "ONLINE|ADMIN"; timestamptz deposit_due_at; varchar confirmed_by "MANUAL|AUTO"; uuid confirmed_admin_id FK; varchar cancel_reason; smallint admitted_count "0~quantity"; int version }
    price_tiers { uuid id PK; uuid performance_id FK; varchar name "공연 안 UK"; int price "1~1000000"; varchar visibility "PUBLIC|LINK_ONLY"; varchar link_token UK; smallint sort_order; bool is_active }
    reservation_items { uuid id PK; uuid reservation_id FK; uuid tier_id FK "NULL = 직접 입력"; varchar tier_name "스냅숏"; int unit_price "스냅숏"; smallint quantity; int line_amount }
    admission_logs { uuid id PK; uuid reservation_id FK; smallint delta; smallint admitted_after; uuid admin_id FK }
    actor_profiles { uuid id PK; uuid member_id FK; varchar profile_image_url; varchar intro; varchar sns_url; date activity_start; int display_order }
    actor_filmographies { uuid id PK; uuid actor_profile_id FK; varchar title; varchar role; smallint year; smallint sort_order }
    applications { uuid id PK; varchar app_type; uuid performance_id FK; varchar applicant_name; varchar phone; date preferred_date; varchar status "PENDING|APPROVED|REJECTED"; timestamptz privacy_agreed_at; timestamptz processed_at; uuid member_id FK; bool interest_undecided "V1_0_7"; timestamptz contacted_at "V1_0_7"; varchar contact_note "V1_0_7"; varchar progress "RECEIVED|SCHEDULED|COMPLETED|JOINED|DROPPED V1_0_7"; timestamptz progress_updated_at "V1_0_7" }
    application_performances { uuid application_id PK,FK; uuid performance_id PK,FK; timestamptz created_at }
    galleries { uuid id PK; varchar category; varchar image_url; varchar description; timestamptz deleted_at }
    schedules { uuid id PK; varchar title; varchar type "PRACTICE|SHOW|EVENT|ETC"; timestamptz start_at; timestamptz end_at; uuid class_id FK; uuid performance_id FK; varchar status "ACTIVE|CANCELLED V1_0_6"; varchar cancel_reason "V1_0_6"; timestamptz cancelled_at "V1_0_6"; bool observation_closed "V1_0_6"; timestamptz deleted_at }
    staff { uuid id PK; varchar name; varchar role; varchar profile_image_url; varchar bio; int display_order; bool is_visible; timestamptz deleted_at }
    popups { uuid id PK; varchar image_url; varchar link_url; date start_date; date end_date; bool is_active; timestamptz deleted_at }
```

## 마이그레이션 목록

| 버전 | 내용 |
| --- | --- |
| V1 | 테이블 14개 · CHECK · 인덱스 · updated_at 트리거 · 신청서 변경 규칙 트리거(내용 불변 · 상태 한 방향 · TRUNCATE 금지) |
| V1_0_1 | 런타임 역할 `sam_app`(NOLOGIN) — 테이블별 DML 만 |
| V1_0_2 | 앱 테이블 RLS + `sam_app_all` 정책, anon·authenticated·PUBLIC 권한 회수, 끝 검사(위반 시 롤백) |
| V1_0_3 | (Supabase 에만) Storage 버킷 `media` — public · 10MB · jpeg/png/webp |
| V1_0_4 | 예매 1단계(U24 R1 + 가격 등급 §11.10): `shows` 반 선택(FK SET NULL)·`booking_enabled`·`updated_at`·UNIQUE(공연·날짜·시각 — 중복이 있으면 한국어 오류로 롤백), `booking_policies`·`price_tiers`(1원 이상 · PUBLIC/LINK_ONLY 토큰)·`reservations`·`reservation_items`(등급 줄 · 직접 입력 줄)·`admission_logs` 신규(RLS·정책·GRANT — 예매 줄·입장 기록은 UPDATE 없음), `members.invite_code`, 예매 변경 규칙 트리거(접수 내용·동의 시각 불변, 회차-공연 짝), 입장 기록 불변 트리거, 끝 검사 |
| V1_0_6(임시) | 일정 취소(U29, T-SA): `schedules.status`(ACTIVE 기본 — 기존 행 ACTIVE)·`cancel_reason`(≤50)·`cancelled_at`·`observation_closed` + 짝 CHECK + `(status, start_at)` 부분 인덱스. 권한 변경 없음 |
| V1_0_7(임시) | 신청 관심 작품·연락·진행(U31, T-SA): `application_performances` 신규(CASCADE·RLS·정책·GRANT SELECT/INSERT/DELETE·끝 검사), `applications.interest_undecided`·`contacted_at`·`contact_note`(≤200)·`progress`(기본 RECEIVED — 기존 거절 → DROPPED, 단원 등록 상담 → JOINED)·`progress_updated_at` + CHECK(JOINED 는 상담만, 거절이면 DROPPED) |

**이어 붙일 자리(R2·R3)**: V1_0_5 `deposit_notifications.reservation_id → reservations(id) ON DELETE SET NULL`(파기 때 함께 지움), V1_0_6 `show_role_casts.show_id → shows(id) ON DELETE CASCADE` — V1_0_4 의 테이블·컬럼 이름을 바꾸지 않고 FK 만 더한다.
