-- TrashPay Schools: cloud setup for Supabase.
-- Run this once: Supabase dashboard > SQL Editor > New query > paste > Run.

-- ---------------------------------------------------------------- tables

create table if not exists public.profiles (
  id uuid primary key,
  name text not null default '',
  phone text not null default '',
  ewallet text not null default '',
  role text not null default 'student' check (role in ('student', 'admin')),
  balance numeric not null default 0,
  total_kg numeric not null default 0,
  created_at timestamptz not null default now()
);

create table if not exists public.transactions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  type text not null check (type in ('deposit', 'withdraw')),
  status text not null check (status in ('pending', 'approved', 'rejected', 'completed')),
  kg numeric not null default 0,
  amount numeric not null default 0,
  note text not null default '',
  created_at timestamptz not null default now(),
  reviewed_at timestamptz
);

create index if not exists transactions_user_idx on public.transactions (user_id, created_at desc);
create index if not exists transactions_status_idx on public.transactions (type, status);

-- -------------------------------------------------------------- security
-- Nobody can write to these tables directly. All changes go through the
-- functions below, which check who is calling.

alter table public.profiles enable row level security;
alter table public.transactions enable row level security;

create or replace function public.is_admin()
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (
    select 1 from public.profiles where id = auth.uid() and role = 'admin'
  );
$$;

drop policy if exists "read own or admin profile" on public.profiles;
create policy "read own or admin profile" on public.profiles
  for select using (id = auth.uid() or public.is_admin());

drop policy if exists "read own or admin transactions" on public.transactions;
create policy "read own or admin transactions" on public.transactions
  for select using (user_id = auth.uid() or public.is_admin());

-- ----------------------------------------------- profile on registration

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, name, phone, ewallet)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'name', ''),
    coalesce(new.raw_user_meta_data ->> 'phone', split_part(new.email, '@', 1)),
    coalesce(new.raw_user_meta_data ->> 'ewallet', '')
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- -------------------------------------------------------------- functions

-- Student: record a weighing (PENDING until the admin approves it).
create or replace function public.submit_weighing(p_kg numeric)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  t public.transactions;
begin
  if auth.uid() is null then
    raise exception 'You are not signed in.';
  end if;
  if p_kg is null or p_kg <= 0 or p_kg > 100 then
    raise exception 'Weight must be between 0 and 100 kg.';
  end if;
  insert into public.transactions (user_id, type, status, kg, amount, note)
  values (auth.uid(), 'deposit', 'pending', p_kg, round(p_kg * 2500, 2), 'Waste weighing')
  returning * into t;
  return to_jsonb(t);
end;
$$;

-- Admin: approve or reject a pending weighing (approve credits the balance).
create or replace function public.review_weighing(p_tx uuid, p_approve boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  t public.transactions;
begin
  if not public.is_admin() then
    raise exception 'Only the admin can review weighings.';
  end if;
  select * into t from public.transactions
    where id = p_tx and type = 'deposit' and status = 'pending'
    for update;
  if not found then
    raise exception 'This weighing is no longer pending.';
  end if;
  update public.transactions
    set status = case when p_approve then 'approved' else 'rejected' end,
        reviewed_at = now()
    where id = p_tx;
  if p_approve then
    update public.profiles
      set balance = round(balance + t.amount, 2),
          total_kg = round(total_kg + t.kg, 2)
      where id = t.user_id;
  end if;
end;
$$;

-- Student: simulated payout of p_amount, or of the whole balance when null.
create or replace function public.withdraw(p_amount numeric default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  p public.profiles;
  v numeric;
  t public.transactions;
begin
  if auth.uid() is null then
    raise exception 'You are not signed in.';
  end if;
  select * into p from public.profiles where id = auth.uid() for update;
  if not found then
    raise exception 'Student not found.';
  end if;
  v := coalesce(p_amount, p.balance);
  if v < 10000 then
    raise exception 'Minimum withdrawal is Rp 10.000.';
  end if;
  if v > p.balance then
    raise exception 'Insufficient balance.';
  end if;
  update public.profiles set balance = round(balance - v, 2) where id = p.id;
  insert into public.transactions (user_id, type, status, kg, amount, note)
  values (p.id, 'withdraw', 'completed', 0, round(v, 2), 'Payout to ' || p.ewallet)
  returning * into t;
  return to_jsonb(t);
end;
$$;

-- Admin: add 2 demo students and 2 new pending weighings for a presentation.
create or replace function public.seed_demo_data()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'Only the admin can add demo data.';
  end if;
  insert into public.profiles (id, name, phone, ewallet) values
    ('00000000-0000-0000-0000-0000000000a1', 'Aulia Rahma', '081234567801', 'DANA 081234567801'),
    ('00000000-0000-0000-0000-0000000000a2', 'Rizky Pratama', '081234567802', 'GoPay 081234567802')
  on conflict (id) do nothing;
  insert into public.transactions (user_id, type, status, kg, amount, note) values
    ('00000000-0000-0000-0000-0000000000a1', 'deposit', 'pending', 6.5, 16250, 'Waste weighing'),
    ('00000000-0000-0000-0000-0000000000a2', 'deposit', 'pending', 4.0, 10000, 'Waste weighing');
end;
$$;

-- ----------------------------------------------------------- admin account
-- 1) Dashboard > Authentication > Users > Add user > Create new user:
--      email    principal@trashpay.school
--      password admin123
--      tick "Auto Confirm User"
-- 2) Then run this line:
--      update public.profiles set role = 'admin' where phone = 'principal';
