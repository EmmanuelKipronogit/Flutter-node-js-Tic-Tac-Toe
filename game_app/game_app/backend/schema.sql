create table if not exists users (
  id serial primary key,
  name text not null,
  email text unique not null,
  hash text not null,
  verified boolean not null default false,
  wins int not null default 0,
  losses int not null default 0,
  draws int not null default 0,
  created_at timestamptz not null default now()
);

create table if not exists login_codes (
  id uuid primary key,
  user_id int not null references users(id) on delete cascade,
  code_hash text not null,
  expires_at timestamptz not null,
  attempts int not null default 0,
  sent_at timestamptz not null default now()
);
