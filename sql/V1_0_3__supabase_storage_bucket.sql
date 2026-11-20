-- ----------------------------------------------------------------------
-- V1_0_3: Supabase Storage 버킷 `media` (FN-18 이미지 업로드) — Supabase 에서만 적용되는 조건부 마이그레이션
-- 배경: 이미지는 서버가 발급한 서명 업로드 URL 로 브라우저가 Storage 에 직접 올린다(Vercel 본문 4.5MB 회피).
--       버킷에서도 형식·크기를 제한해 서버 검사가 뚫려도 저장소가 막게 한다(가이드 A17.1 "파일 업로드",
--       https://supabase.com/docs/guides/storage/buckets/creating-buckets — SQL 로 storage.buckets 에 INSERT).
-- 범위: storage.buckets 가 있을 때만(Supabase) media 버킷을 만들거나 설정을 맞춘다.
--       public = true(공개 URL 로 읽기 — 홈페이지·대시보드 <img>), file_size_limit = 10MB(갤러리·상세 상한, develop FN-18),
--       allowed_mime_types = jpeg · png · webp(SVG 제외).
--       storage.objects 에는 정책을 만들지 않는다: 쓰기는 서버의 secret key(RLS 우회)와 그 키로 만든 서명 업로드 토큰만,
--       anon·authenticated 의 업로드·삭제는 정책이 없어 거부된다(Storage 는 정책 없는 버킷 업로드를 막는다 —
--       https://supabase.com/docs/guides/storage/security/access-control ).
--       로컬 Postgres(storage 스키마 없음)에서는 NOTICE 만 남기고 아무것도 하지 않는다 — 로컬·E2E 는 서버의
--       대체 저장소 어댑터(STORAGE_DRIVER=local)를 쓴다.
-- 안전성: ON CONFLICT 로 멱등. 버킷 이름은 서버 env SUPABASE_STORAGE_BUCKET(기본 media)과 같아야 한다 —
--         바꾸려면 새 마이그레이션으로 버킷을 추가하고 env 를 함께 바꾼다.
-- ----------------------------------------------------------------------

DO $$
BEGIN
    IF to_regclass('storage.buckets') IS NULL THEN
        RAISE NOTICE 'storage.buckets 없음(로컬 Postgres) — media 버킷 생성을 건너뛴다';
        RETURN;
    END IF;

    INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
    VALUES ('media', 'media', true, 10485760, ARRAY['image/jpeg', 'image/png', 'image/webp'])
    ON CONFLICT (id) DO UPDATE
        SET public = EXCLUDED.public,
            file_size_limit = EXCLUDED.file_size_limit,
            allowed_mime_types = EXCLUDED.allowed_mime_types;
END
$$;
