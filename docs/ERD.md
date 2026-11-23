# ERD — SAM 의정부

> 최종 반영: **V1_0_17**(U48 캐스트 사진·회차 팀 지정, 미배포) · 이전 V1_0_16(임시 — U46 연습실 시간 막기) · 이전 V1_0_15(임시 — U45 팀 소속 배우·연습실 참석자) · 이전 V1_0_14(임시 — U43 입금 알림 기기 등록) · 이전 **V1_0_13** (2026-11-23 — v1.3.1: U41 V1_0_12 초대 유형별 가격 · SAM 관계자 확인 · R2 V1_0_13 입금 알림 자동 확인). 이전 V1_0_11 (2026-11-20 — v1.3.0: T-PR V1_0_8 팀 계정·연습실 예약 · T-SEAT V1_0_9 좌석 지정·초대자 구분 · R3 V1_0_10 배역·캐스팅·크레딧·연출진 연혁 · U39 V1_0_11 단원 공개 동의일. U41 은 다음 릴리스로 미룸). 이전: V1_0_7(v1.2.0). 정본은 `sql/` 의 Flyway 마이그레이션이고, 서버 `prisma/schema.prisma` 는 `prisma db pull` 파생물이다.
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
    performances ||--o{ team_accounts : "팀 계정(V1_0_8, CASCADE)"
    performances ||--o{ room_reservations : "연습실 예약(V1_0_8, CASCADE)"
    team_accounts |o--o{ room_reservations : "예약 팀(SET NULL)"
    team_accounts ||--o{ team_members : "소속 배우(V1_0_15, CASCADE)"
    performances ||--o{ performance_group_photos : "단체샷 0~4장(V1_0_17, CASCADE)"
    performance_roles ||--o{ cast_role_photos : "배역 개인샷(V1_0_17, CASCADE)"
    actor_profiles ||--o{ cast_role_photos : "배우(CASCADE)"
    team_accounts |o--o{ shows : "회차 팀 지정(V1_0_17, SET NULL · 폐기 시 NULL)"
    members ||--o{ team_members : "배우(CASCADE)"
    room_reservations ||--o{ room_reservation_attendees : "참석자(V1_0_15, CASCADE)"
    members ||--o{ room_reservation_attendees : "배우(CASCADE)"
    performances ||--o{ reservations : "예매(공연 단위 예매번호)"
    shows ||--o{ reservations : "예매(RESTRICT — 예매 있는 회차 삭제 불가)"
    members |o--o{ reservations : "초대 단원(SET NULL)"
    admins |o--o{ reservations : "확정 관리자(SET NULL)"
    reservations ||--o{ admission_logs : "입장 기록(추가만, CASCADE)"
    performances ||--o{ price_tiers : "가격 등급(CASCADE)"
    reservations ||--|{ reservation_items : "등급별 줄(CASCADE)"
    price_tiers |o--o{ reservation_items : "등급(RESTRICT — 직접 입력 줄은 NULL)"
    admins |o--o{ admission_logs : "처리 관리자(SET NULL)"
    applications ||--o{ application_performances : "관심·희망 작품(V1_0_6, CASCADE)"
    performances ||--o{ application_performances : "관심 대상(CASCADE)"
    admins ||--o{ push_subscriptions : "기기별 푸시 구독(V1_0_7, CASCADE)"
    reservations ||--o{ deposit_notifications : "입금 알림 판정(V1_0_13, CASCADE)"
    admins |o--o{ deposit_devices : "등록 관리자(V1_0_14, SET NULL)"
    deposit_devices |o--o{ deposit_notifications : "보낸 기기(V1_0_14, SET NULL)"
    shows ||--o| show_seat_layouts : "좌석 배치 크기(V1_0_9, CASCADE)"
    shows ||--o{ show_seats : "격자 칸(V1_0_9, CASCADE)"
    reservations ||--o{ reservation_seats : "예매 좌석(V1_0_9, CASCADE)"
    show_seats ||--o{ reservation_seats : "좌석(RESTRICT)"
    performances ||--o{ performance_roles : "배역(CASCADE · name NULL = 출연 묶음, 공연당 1)"
    performance_roles ||--o{ role_casts : "기본 캐스트(CASCADE)"
    performance_roles ||--o{ show_role_casts : "회차 지정(CASCADE)"
    shows ||--o{ show_role_casts : "회차 지정(CASCADE)"
    actor_profiles ||--o{ role_casts : "배우(CASCADE)"
    actor_profiles ||--o{ show_role_casts : "배우(CASCADE)"
    performances ||--o{ performance_credits : "참여자(CASCADE)"
    staff |o--o{ performance_credits : "연출진 연결(SET NULL — 이름 스냅숏)"
    members |o--o{ performance_credits : "단원 연결(SET NULL — 이름 스냅숏)"
    staff ||--o{ staff_histories : "연혁(순서, CASCADE)"

    admins { uuid id PK; varchar username UK; varchar password_hash "argon2id PHC"; int consecutive_failures; timestamptz locked_until; timestamptz hard_locked_at; int session_version }
    performances { uuid id PK; varchar title; varchar type "MUSICAL|PLAY|SEMINAR|ETC"; varchar status "UPCOMING|ONGOING|ENDED"; text description; varchar poster_image_url; bool is_visible; bool cast_public "V1_0_8 기본 false"; timestamptz deleted_at }
    performance_detail_images { uuid id PK; uuid performance_id FK; varchar image_url; smallint sort_order }
    classes { uuid id PK; uuid performance_id FK; varchar name; time start_time; time end_time; date deadline; varchar location; varchar status "ACTIVE|INACTIVE" }
    class_days { uuid class_id PK; smallint day_of_week PK }
    shows { uuid id PK; uuid class_id FK "NULL 허용(V1_0_4)"; uuid performance_id FK; date show_date; time start_time; varchar venue; varchar status "UPCOMING|BOOKING_OPEN|COMPLETED"; int total_seats; bool booking_enabled "V1_0_4"; timestamptz booking_open_at; uuid team_account_id FK "V1_0_17 NULL, 같은 공연·폐기 안 된 팀만(트리거)" }
    members { uuid id PK; varchar name; varchar type "GENERAL|ACTOR"; varchar phone; bool is_visible; date joined_at; varchar invite_code UK "V1_0_4"; date public_consent_at "V1_0_11"; timestamptz deleted_at }
    booking_policies { uuid performance_id PK; varchar deposit_bank; varchar deposit_account_number; varchar deposit_account_holder; smallint max_tickets_per_booking "1~20"; smallint deposit_deadline_hours "1~168"; varchar refund_policy_text; varchar inquiry_contact "선택, URL 은 https" }
    reservations { uuid id PK; uuid performance_id FK; uuid show_id FK; char code "4자리, 공연 안 UK"; smallint quantity "줄 합"; int amount "줄 합 또는 관리자 덮어쓰기"; bool tier_token_used; varchar booker_name; varchar booker_phone "숫자만"; varchar depositor_name; uuid inviter_member_id FK; varchar inviter_note; varchar status "PENDING|CONFIRMED|CANCELLED"; varchar source "ONLINE|ADMIN"; timestamptz deposit_due_at; varchar confirmed_by "MANUAL|AUTO"; uuid confirmed_admin_id FK; varchar cancel_reason; smallint admitted_count "0~quantity"; int version }
    price_tiers { uuid id PK; uuid performance_id FK; varchar name "공연 안 UK"; int price "1~1000000"; varchar visibility "PUBLIC|LINK_ONLY"; varchar link_token UK; smallint sort_order; bool is_active }
    reservation_items { uuid id PK; uuid reservation_id FK; uuid tier_id FK "NULL = 직접 입력"; varchar tier_name "스냅숏"; int unit_price "스냅숏"; smallint quantity; int line_amount }
    admission_logs { uuid id PK; uuid reservation_id FK; smallint delta; smallint admitted_after; uuid admin_id FK }
    deposit_notifications { uuid id PK; timestamptz received_at; varchar source; varchar app_package; varchar app_name; varchar title; varchar body_redacted "잔액 제거"; int parsed_amount; varchar status "AUTO_CONFIRMED|PARTIAL|NEEDS_REVIEW|UNMATCHED|MANUALLY_MATCHED|IGNORED|IGNORED_SOURCE"; varchar review_reason; uuid reservation_id FK; char content_hash; char dedupe_key UK; uuid resolved_admin_id FK; uuid device_id FK "V1_0_14, 비밀값 수신은 NULL" }
    deposit_devices { uuid id PK; varchar name "1~40"; char token_hash UK "sha256 hex — 평문 저장 안 함"; uuid created_by FK; timestamptz last_seen_at; timestamptz revoked_at "해제" }
    push_subscriptions { uuid id PK; uuid admin_id FK; varchar endpoint UK "https"; varchar p256dh; varchar auth; varchar user_agent "기기 이름"; timestamptz last_success_at }
    show_seat_layouts { uuid show_id PK; smallint row_count "1~40"; smallint col_count "1~60" }
    show_seats { uuid id PK; uuid show_id FK; smallint row_index "0~39"; smallint col_index "0~59"; varchar kind "SEAT|AISLE|VOID"; varchar row_label "SEAT 만"; smallint seat_number "SEAT 만" }
    reservation_seats { uuid reservation_id PK; uuid seat_id PK; uuid show_id FK; bool active "부분 UK(show_id, seat_id) WHERE active" }
    actor_profiles { uuid id PK; uuid member_id FK; varchar profile_image_url; varchar intro; varchar sns_url; date activity_start; int display_order }
    actor_filmographies { uuid id PK; uuid actor_profile_id FK; varchar title; varchar role; smallint year; smallint sort_order }
    applications { uuid id PK; varchar app_type; uuid performance_id FK; varchar applicant_name; varchar phone; date preferred_date; varchar status "PENDING|APPROVED|REJECTED"; timestamptz privacy_agreed_at; timestamptz processed_at; uuid member_id FK; bool interest_undecided "V1_0_7"; timestamptz contacted_at "V1_0_7"; varchar contact_note "V1_0_7"; varchar progress "RECEIVED|SCHEDULED|COMPLETED|JOINED|DROPPED V1_0_7"; timestamptz progress_updated_at "V1_0_7" }
    application_performances { uuid application_id PK,FK; uuid performance_id PK,FK; timestamptz created_at }
    galleries { uuid id PK; varchar category; varchar image_url; varchar description; timestamptz deleted_at }
    schedules { uuid id PK; varchar title; varchar type "PRACTICE|SHOW|EVENT|ETC"; timestamptz start_at; timestamptz end_at; uuid class_id FK; uuid performance_id FK; varchar status "ACTIVE|CANCELLED V1_0_6"; varchar cancel_reason "V1_0_6"; timestamptz cancelled_at "V1_0_6"; bool observation_closed "V1_0_6"; timestamptz deleted_at }
    staff { uuid id PK; varchar name; varchar role; varchar profile_image_url; varchar bio; int display_order; bool is_visible; timestamptz deleted_at }
    performance_roles { uuid id PK; uuid performance_id FK; varchar name "NULL = 출연 묶음"; varchar description; smallint sort_order; bool is_recruiting }
    role_casts { uuid id PK; uuid role_id FK; uuid actor_profile_id FK; varchar note; smallint sort_order }
    show_role_casts { uuid id PK; uuid show_id FK; uuid role_id FK; uuid actor_profile_id FK; varchar note; smallint sort_order }
    performance_credits { uuid id PK; uuid performance_id FK; varchar title; uuid staff_id FK; uuid member_id FK; varchar display_name "스냅숏"; smallint sort_order; bool is_visible }
    staff_histories { uuid id PK; uuid staff_id FK; smallint year; varchar content; smallint sort_order }
    popups { uuid id PK; varchar image_url; varchar link_url; date start_date; date end_date; bool is_active; timestamptz deleted_at }
    team_accounts { uuid id PK; uuid performance_id FK; varchar label "A,B…"; varchar username UK "lower() 유일"; varchar password_hash "argon2id"; text password_enc "AES-256-GCM iv.ct.tag"; int session_version; int consecutive_failures; timestamptz locked_until; bool is_active; timestamptz revoked_at; varchar team_photo_url "V1_0_17 팀샷" }
    performance_group_photos { uuid id PK; uuid performance_id FK; varchar image_url; smallint sort_order "0~3, (공연,순서) UK DEFERRABLE"; timestamptz created_at }
    cast_role_photos { uuid role_id PK; uuid actor_profile_id PK; varchar image_url; timestamptz created_at; timestamptz updated_at }
    room_reservations { uuid id PK; uuid team_account_id FK "NULL"; uuid performance_id FK; varchar team_name "스냅숏"; timestamptz start_at; timestamptz end_at "EXCLUDE gist &&"; varchar memo; timestamptz deleted_at }
    team_members { uuid team_account_id PK "FK"; uuid member_id PK "FK"; timestamptz created_at }
    room_reservation_attendees { uuid reservation_id PK "FK"; uuid member_id PK "FK"; timestamptz created_at }
    room_blocks { uuid id PK; varchar title "30자"; varchar memo; varchar repeat "NONE|WEEKLY"; smallint_arr weekdays "ISO 1~7"; smallint start_minutes; smallint end_minutes "0~1440, 30분 단위"; date start_date; date end_date; date_arr skip_dates }
```

## 마이그레이션 목록

| 버전 | 내용 |
| --- | --- |
| V1 | 테이블 14개 · CHECK · 인덱스 · updated_at 트리거 · 신청서 변경 규칙 트리거(내용 불변 · 상태 한 방향 · TRUNCATE 금지) |
| V1_0_1 | 런타임 역할 `sam_app`(NOLOGIN) — 테이블별 DML 만 |
| V1_0_2 | 앱 테이블 RLS + `sam_app_all` 정책, anon·authenticated·PUBLIC 권한 회수, 끝 검사(위반 시 롤백) |
| V1_0_3 | (Supabase 에만) Storage 버킷 `media` — public · 10MB · jpeg/png/webp |
| V1_0_4 | 예매 1단계(U24 R1 + 가격 등급 §11.10): `shows` 반 선택(FK SET NULL)·`booking_enabled`·`updated_at`·UNIQUE(공연·날짜·시각 — 중복이 있으면 한국어 오류로 롤백), `booking_policies`·`price_tiers`(1원 이상 · PUBLIC/LINK_ONLY 토큰)·`reservations`·`reservation_items`(등급 줄 · 직접 입력 줄)·`admission_logs` 신규(RLS·정책·GRANT — 예매 줄·입장 기록은 UPDATE 없음), `members.invite_code`, 예매 변경 규칙 트리거(접수 내용·동의 시각 불변, 회차-공연 짝), 입장 기록 불변 트리거, 끝 검사 |
| V1_0_5(v1.2.0, 임시 V1_0_6) | 일정 취소(U29, T-SA): `schedules.status`(ACTIVE 기본 — 기존 행 ACTIVE)·`cancel_reason`(≤50)·`cancelled_at`·`observation_closed` + 짝 CHECK + `(status, start_at)` 부분 인덱스. 권한 변경 없음 |
| V1_0_6(v1.2.0, 임시 V1_0_7) | 신청 관심 작품·연락·진행(U31, T-SA): `application_performances` 신규(CASCADE·RLS·정책·GRANT SELECT/INSERT/DELETE·끝 검사), `applications.interest_undecided`·`contacted_at`·`contact_note`(≤200)·`progress`(기본 RECEIVED — 기존 거절 → DROPPED, 단원 등록 상담 → JOINED)·`progress_updated_at` + CHECK(JOINED 는 상담만, 거절이면 DROPPED) |
| V1_0_8(v1.3.0, 임시 V1_0_9) | 팀 계정·연습실 예약(U34, T-PR): `performances.team_prefix`, `team_accounts`(아이디 lower 유일 · argon2id 해시 + AES-GCM 사본 · 잠금·세션 버전), `room_reservations`(**EXCLUDE gist tstzrange [) && — 겹침 금지** · 30분 단위·30분~4시간 CHECK · 소프트 삭제), RLS·정책·GRANT, 끝 검사. 배포 때 빈 번호로 재번호(기획 §22.3) |

| V1_0_7(v1.2.0, 임시 V1_0_11) | 새 예매 푸시(U37): `push_subscriptions` 신규(관리자 × 기기, endpoint 유일·https, 관리자 삭제 CASCADE, RLS·정책·GRANT), 끝 검사 |
| V1_0_12(v1.3.1, U41) | 초대한 사람 3종·초대 유형별 가격: `price_tiers.role`(BASE\|SAM_RELATED, 공연당 역할 1개 부분 유니크, 역할 등급은 PUBLIC), `reservations.inviter_category` 에 SAM_RELATED(단원 id 는 MEMBER 만), `reservations.sam_related_acknowledged_at`(온라인 SAM 관계자 필수 CHECK). 운영 이전: 역할 없는 공연의 사용 중 PUBLIC 등급 1개(sort_order·id 앞)를 BASE 로 — SAM_RELATED 는 만들지 않음(관리자 입력 전까지 NOT_READY) |
| V1_0_14(임시, U43) | 입금 알림 기기 등록: `deposit_devices` 신규(이름 · 토큰 SHA-256 해시 UNIQUE · 등록 관리자 SET NULL · 마지막 수신 · 해제 시각 — 행은 지우지 않음, GRANT 에 DELETE 없음), `deposit_notifications.device_id`(NULL, SET NULL) + 원문 불변 트리거에 포함, RLS·정책·GRANT, 끝 검사. 해제 안 된 기기 상한 5대는 서버가 센다 |
| V1_0_15(임시, U45) | 팀 소속 배우·연습실 참석자: `team_members`(팀 계정·단원 조합 PK, 둘 다 CASCADE — 폐기된 팀은 서버가 정리), `room_reservation_attendees`(예약·단원 조합 PK, 둘 다 CASCADE — 예약 파기와 함께), RLS·정책·GRANT(SELECT·INSERT·DELETE), 끝 검사. "캐스트 배우만 팀에"·"팀 소속 배우만 참석자로"는 서버가 검사 |
| V1_0_16(임시, U46) | 연습실 시간 막기: `room_blocks`(제목·메모·반복 NONE/WEEKLY·요일 ISO·시작/끝 분 30분 단위 30분~하루·시작/종료일 ≤2년·이 날만 해제 skip_dates), 독립 테이블(FK 없음), RLS·정책·GRANT, 끝 검사. 발생분은 행으로 펼치지 않고 서버가 규칙으로 계산 |
| V1_0_17(U48) | 캐스트 사진·회차 팀 지정: `performance_group_photos`(공연당 0~4장 — sort_order 0~3 CHECK + (공연, 순서) UNIQUE DEFERRABLE), `team_accounts.team_photo_url`(NULL), `cast_role_photos`(role_id·actor_profile_id 조합 PK = role_casts 키, 배역·배우 프로필 CASCADE — role_casts 에는 FK 없음: 기본 캐스트 저장이 행을 다시 만든다), `shows.team_account_id`(NULL, SET NULL, 트리거 `shows_guard_team_account` 가 같은 공연·폐기 안 된 팀만 허용, `team_accounts_clear_show_team` 이 폐기 때 NULL), RLS·정책·GRANT, 함수 EXECUTE 회수, 끝 검사 |
| V1_0_13(v1.3.1, R2) | 입금 알림 자동 확인(R2): `deposit_notifications` 신규(출처 앱 패키지·이름 · 허용 밖 앱 IGNORED_SOURCE · 잔액 지운 본문 · 해석 금액 · 판정 상태/이유 · 멱등 키 UNIQUE(내용 해시 + 분) · 예매 CASCADE · 관리자 처리), 원문 불변 트리거, RLS·정책·GRANT, 끝 검사 |
| V1_0_11(v1.3.0, U39, 임시 V1_0_12) | 단원 홈페이지 공개 동의일: `members.public_consent_at DATE NULL`(기존 행 NULL). 권한·트리거 변경 없음 |

**이어 붙일 자리(R2·R3 — v1.2.0 이 V1_0_5~7 을 썼으므로 다음 빈 번호로)**: `deposit_notifications.reservation_id → reservations(id) ON DELETE SET NULL`(파기 때 함께 지움), `show_role_casts.show_id → shows(id) ON DELETE CASCADE` — V1_0_4 의 테이블·컬럼 이름을 바꾸지 않고 FK 만 더한다.
| V1_0_9(v1.3.0, 임시 V1_0_10) | 좌석 지정(U35): `performances.seat_selection_enabled`, `show_seat_layouts`·`show_seats`(칸 UPDATE 없음)·`reservation_seats`(살아 있는 예매만 부분 유니크) 신규, 예매 상태 ↔ 좌석 active 동기화 트리거, 예매 좌석 쓰기 규칙 트리거 · 초대자 드롭다운(U36): `members.inviter_listed`(기본 true)·`reservations.inviter_category`(MEMBER\|STAFF_RELATED), 끝 검사 |
| V1_0_10(v1.3.0, 임시 V1_0_8) | R3(U26·U28·U33): `performances.cast_public`(기본 false), `performance_roles`(name NULL = "출연" 묶음 — 부분 유니크 공연당 1)·`role_casts`·`show_role_casts`·`performance_credits`(연결 하나 또는 이름만 · 스냅숏)·`staff_histories` 신규(RLS·정책·GRANT), 끝 검사 |

**이어 붙일 자리(R2·R3)**: V1_0_5 `deposit_notifications.reservation_id → reservations(id) ON DELETE SET NULL`(파기 때 함께 지움), V1_0_6 `show_role_casts.show_id → shows(id) ON DELETE CASCADE` — V1_0_4 의 테이블·컬럼 이름을 바꾸지 않고 FK 만 더한다.
