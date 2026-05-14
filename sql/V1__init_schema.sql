-- V1__init_schema.sql

-- 1. ENUM Types
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'performance_type') THEN
        CREATE TYPE performance_type AS ENUM ('musical', 'play', 'seminar', 'etc');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'performance_status') THEN
        CREATE TYPE performance_status AS ENUM ('upcoming', 'ongoing', 'ended');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'class_status') THEN
        CREATE TYPE class_status AS ENUM ('active', 'inactive');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'show_status') THEN
        CREATE TYPE show_status AS ENUM ('upcoming', 'booking_open', 'completed');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'payment_status') THEN
        CREATE TYPE payment_status AS ENUM ('pending', 'confirmed', 'cancelled');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'member_type') THEN
        CREATE TYPE member_type AS ENUM ('general', 'actor');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'application_status') THEN
        CREATE TYPE application_status AS ENUM ('pending', 'approved', 'rejected');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'schedule_type') THEN
        CREATE TYPE schedule_type AS ENUM ('practice', 'show', 'event', 'etc');
    END IF;
END $$;

-- 2. Tables

-- performances (작품)
CREATE TABLE performances (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    title VARCHAR(100) NOT NULL,
    type performance_type NOT NULL,
    status performance_status NOT NULL,
    description TEXT,
    poster_image VARCHAR(500),
    detail_images JSONB,
    is_visible BOOLEAN DEFAULT true,
    created_at TIMESTAMP NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMP NOT NULL DEFAULT NOW()
);

-- classes (운영반)
CREATE TABLE classes (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    performance_id UUID NOT NULL,
    name VARCHAR(100) NOT NULL,
    day_of_week VARCHAR(10),
    start_time TIME,
    end_time TIME,
    location VARCHAR(200),
    actors JSONB,
    status class_status NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT NOW(),
    
    CONSTRAINT fk_classes_performance_id FOREIGN KEY (performance_id) REFERENCES performances(id) ON DELETE CASCADE
);

-- shows (공연 회차)
CREATE TABLE shows (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    class_id UUID NOT NULL,
    performance_id UUID NOT NULL,
    show_date DATE NOT NULL,
    start_time TIME NOT NULL,
    end_time TIME,
    venue VARCHAR(200),
    status show_status NOT NULL,
    booking_open_at TIMESTAMP,
    total_seats INT,
    created_at TIMESTAMP NOT NULL DEFAULT NOW(),
    
    CONSTRAINT fk_shows_class_id FOREIGN KEY (class_id) REFERENCES classes(id) ON DELETE CASCADE,
    CONSTRAINT fk_shows_performance_id FOREIGN KEY (performance_id) REFERENCES performances(id) ON DELETE CASCADE
);

-- bookings (예매 내역)
CREATE TABLE bookings (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    show_id UUID NOT NULL,
    performance_id UUID NOT NULL,
    actor_id UUID,
    booker_name VARCHAR(50) NOT NULL,
    booker_phone VARCHAR(20) NOT NULL,
    amount INT NOT NULL,
    payment_status payment_status NOT NULL,
    depositor_name VARCHAR(50),
    deposited_at TIMESTAMP,
    created_at TIMESTAMP NOT NULL DEFAULT NOW(),
    
    CONSTRAINT fk_bookings_show_id FOREIGN KEY (show_id) REFERENCES shows(id) ON DELETE CASCADE,
    CONSTRAINT fk_bookings_performance_id FOREIGN KEY (performance_id) REFERENCES performances(id) ON DELETE CASCADE
);

-- members (단원)
CREATE TABLE members (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name VARCHAR(50) NOT NULL,
    type member_type NOT NULL,
    phone VARCHAR(20),
    is_visible BOOLEAN DEFAULT false,
    joined_at DATE,
    created_at TIMESTAMP NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMP NOT NULL DEFAULT NOW()
);

-- actor_profiles (배우 프로필)
CREATE TABLE actor_profiles (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    member_id UUID UNIQUE NOT NULL,
    profile_image VARCHAR(500),
    extra_images JSONB,
    intro VARCHAR(200),
    sns_url VARCHAR(500),
    activity_start DATE,
    filmography JSONB,
    display_order INT DEFAULT 0,
    updated_at TIMESTAMP NOT NULL DEFAULT NOW(),
    
    CONSTRAINT fk_actor_profiles_member_id FOREIGN KEY (member_id) REFERENCES members(id) ON DELETE CASCADE
);

-- applications (참관 신청)
CREATE TABLE applications (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    performance_id UUID,
    applicant_name VARCHAR(50) NOT NULL,
    phone VARCHAR(20) NOT NULL,
    preferred_date DATE NOT NULL,
    age INT,
    gender VARCHAR(10),
    motivation TEXT,
    status application_status DEFAULT 'pending',
    processed_at TIMESTAMP,
    created_at TIMESTAMP NOT NULL DEFAULT NOW(),
    
    CONSTRAINT fk_applications_performance_id FOREIGN KEY (performance_id) REFERENCES performances(id) ON DELETE SET NULL
);

-- schedules (일정)
CREATE TABLE schedules (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    title VARCHAR(100) NOT NULL,
    type schedule_type NOT NULL,
    start_at TIMESTAMP NOT NULL,
    end_at TIMESTAMP,
    location VARCHAR(200),
    class_id UUID,
    show_id UUID,
    is_recurring BOOLEAN DEFAULT false,
    recur_rule JSONB,
    created_at TIMESTAMP NOT NULL DEFAULT NOW(),
    
    CONSTRAINT fk_schedules_class_id FOREIGN KEY (class_id) REFERENCES classes(id) ON DELETE SET NULL,
    CONSTRAINT fk_schedules_show_id FOREIGN KEY (show_id) REFERENCES shows(id) ON DELETE SET NULL
);

-- popups (메인 팝업)
CREATE TABLE popups (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    image_url VARCHAR(500) NOT NULL,
    link_url VARCHAR(500),
    start_at DATE NOT NULL,
    end_at DATE NOT NULL,
    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMP NOT NULL DEFAULT NOW()
);

-- static_contents (정적 콘텐츠)
CREATE TABLE static_contents (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    page VARCHAR(50) NOT NULL,
    key VARCHAR(100) NOT NULL,
    value TEXT NOT NULL,
    type VARCHAR(20) NOT NULL,
    updated_at TIMESTAMP NOT NULL DEFAULT NOW()
);

-- galleries (갤러리)
CREATE TABLE galleries (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    category VARCHAR(50) NOT NULL,
    image_url VARCHAR(500) NOT NULL,
    display_order INT DEFAULT 0,
    created_at TIMESTAMP NOT NULL DEFAULT NOW()
);

-- admins (관리자 계정)
CREATE TABLE admins (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    username VARCHAR(50) UNIQUE NOT NULL,
    password_hash VARCHAR(255) NOT NULL,
    role VARCHAR(20) DEFAULT 'admin',
    created_at TIMESTAMP NOT NULL DEFAULT NOW()
);
