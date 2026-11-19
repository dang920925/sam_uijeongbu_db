# ERD — SAM 의정부

> 최종 반영: **V1_0_3** (2026-11-19). 정본은 `sql/` 의 Flyway 마이그레이션이고, 서버 `prisma/schema.prisma` 는 `prisma db pull` 파생물이다.
> 열거값은 VARCHAR + CHECK(UPPER_SNAKE), 시각은 TIMESTAMPTZ, 관리 콘텐츠는 소프트 삭제(`deleted_at`), id 는 UUID(서버가 v7 생성).

```mermaid
erDiagram
    performances ||--o{ performance_detail_images : "상세 이미지(순서)"
    performances ||--o{ classes : "운영반"
    performances ||--o{ shows : "회차"
    performances |o--o{ schedules : "연결 공연(SET NULL)"
    performances |o--o{ applications : "참관 공연(SET NULL)"
    classes ||--o{ class_days : "요일(0=일~6=토)"
    classes ||--o{ shows : "회차"
    classes |o--o{ schedules : "연결 반(SET NULL)"
    members ||--o| actor_profiles : "배우 프로필"
    actor_profiles ||--o{ actor_filmographies : "출연작(순서)"
    members |o--o{ applications : "단원으로 등록(D6, SET NULL)"

    admins { uuid id PK; varchar username UK; varchar password_hash "argon2id PHC"; int consecutive_failures; timestamptz locked_until; timestamptz hard_locked_at; int session_version }
    performances { uuid id PK; varchar title; varchar type "MUSICAL|PLAY|SEMINAR|ETC"; varchar status "UPCOMING|ONGOING|ENDED"; text description; varchar poster_image_url; bool is_visible; timestamptz deleted_at }
    performance_detail_images { uuid id PK; uuid performance_id FK; varchar image_url; smallint sort_order }
    classes { uuid id PK; uuid performance_id FK; varchar name; time start_time; time end_time; date deadline; varchar location; varchar status "ACTIVE|INACTIVE" }
    class_days { uuid class_id PK; smallint day_of_week PK }
    shows { uuid id PK; uuid class_id FK; uuid performance_id FK; date show_date; time start_time; varchar venue; varchar status "UPCOMING|BOOKING_OPEN|COMPLETED"; int total_seats }
    members { uuid id PK; varchar name; varchar type "GENERAL|ACTOR"; varchar phone; bool is_visible; date joined_at; timestamptz deleted_at }
    actor_profiles { uuid id PK; uuid member_id FK; varchar profile_image_url; varchar intro; varchar sns_url; date activity_start; int display_order }
    actor_filmographies { uuid id PK; uuid actor_profile_id FK; varchar title; varchar role; smallint year; smallint sort_order }
    applications { uuid id PK; varchar app_type; uuid performance_id FK; varchar applicant_name; varchar phone; date preferred_date; varchar status "PENDING|APPROVED|REJECTED"; timestamptz privacy_agreed_at; timestamptz processed_at; uuid member_id FK }
    galleries { uuid id PK; varchar category; varchar image_url; varchar description; timestamptz deleted_at }
    schedules { uuid id PK; varchar title; varchar type "PRACTICE|SHOW|EVENT|ETC"; timestamptz start_at; timestamptz end_at; uuid class_id FK; uuid performance_id FK; timestamptz deleted_at }
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
