-- COMMVAGANZA 10.0 - Supabase schema + secure payment review + e-ticket
create extension if not exists pgcrypto;

create table if not exists public.orders (
  id uuid primary key default gen_random_uuid(),
  order_code text unique not null,
  name text not null,
  email text not null,
  wa text not null,
  identitas text not null,
  nomor_id text not null,
  alamat text not null,
  ticket_type text not null,
  qty integer not null check (qty between 1 and 5),
  unit_price integer not null check (unit_price >= 0),
  total_price integer generated always as (qty * unit_price) stored,
  holders jsonb not null default '[]'::jsonb,
  status text not null default 'PENDING' check (status in ('PENDING','PAID','CANCELLED')),
  created_at timestamptz not null default now(),
  paid_at timestamptz,
  payment_submitted_at timestamptz,
  payment_verified_at timestamptz,
  payment_verified_by text,
  payment_rejected_at timestamptz,
  payment_rejection_reason text
);

alter table public.orders add column if not exists payment_submitted_at timestamptz;
alter table public.orders add column if not exists payment_verified_at timestamptz;
alter table public.orders add column if not exists payment_verified_by text;
alter table public.orders add column if not exists payment_rejected_at timestamptz;
alter table public.orders add column if not exists payment_rejection_reason text;

create table if not exists public.tickets (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  ticket_code text unique not null,
  name text not null,
  email text,
  wa text,
  ticket_type text not null,
  event_date date not null default date '2026-09-12',
  event_time text not null default '14:00',
  location text not null default 'Bandar Lampung',
  checked_in_at timestamptz,
  checked_in_by text,
  created_at timestamptz not null default now()
);

create index if not exists tickets_order_id_idx on public.tickets(order_id);
create index if not exists tickets_ticket_code_idx on public.tickets(ticket_code);

create table if not exists public.admin_users (
  user_id uuid primary key references auth.users(id) on delete cascade,
  email text unique not null,
  created_at timestamptz not null default now()
);

create table if not exists public.payment_proofs (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  storage_path text not null unique,
  original_filename text,
  mime_type text,
  file_size bigint,
  submitted_at timestamptz not null default now(),
  submitted_by uuid references auth.users(id) on delete set null
);

create index if not exists payment_proofs_order_id_idx on public.payment_proofs(order_id);

alter table public.orders enable row level security;
alter table public.tickets enable row level security;
alter table public.admin_users enable row level security;
alter table public.payment_proofs enable row level security;

revoke all on table public.admin_users from anon, authenticated;
revoke all on table public.payment_proofs from anon, authenticated;

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path=public,auth
as $$
  select exists (
    select 1 from public.admin_users a
    where a.user_id = auth.uid()
      and lower(a.email) = lower(coalesce(auth.jwt()->>'email',''))
  );
$$;

grant execute on function public.is_admin() to authenticated;

-- Public order creation. Price is determined server-side.
create or replace function public.create_pending_order(
  p_name text, p_email text, p_wa text, p_identitas text, p_nomor_id text, p_alamat text,
  p_ticket_type text, p_qty integer, p_unit_price integer, p_holders jsonb default '[]'::jsonb
) returns table(order_id uuid, order_code text, ticket_codes text[])
language plpgsql
security definer
set search_path=public
as $$
declare
  v_order_id uuid;
  v_order_code text;
  v_codes text[] := '{}';
  v_code text;
  v_name text;
  v_email text;
  v_wa text;
  v_price integer;
  i integer;
begin
  if p_qty is null or p_qty < 1 or p_qty > 5 then raise exception 'Jumlah tiket harus 1 sampai 5'; end if;
  if length(trim(coalesce(p_name,''))) = 0 then raise exception 'Nama wajib diisi'; end if;
  if lower(trim(coalesce(p_ticket_type,''))) <> 'normal sale 2' then raise exception 'Kategori tiket tidak tersedia'; end if;
  if length(trim(coalesce(p_email,''))) = 0 then raise exception 'Email wajib diisi'; end if;
  if length(trim(coalesce(p_wa,''))) = 0 then raise exception 'WhatsApp wajib diisi'; end if;

  v_price := 210000;
  v_order_code := 'CMV-' || upper(substr(md5(gen_random_uuid()::text),1,8));

  insert into public.orders(order_code,name,email,wa,identitas,nomor_id,alamat,ticket_type,qty,unit_price,holders)
  values(v_order_code,trim(p_name),trim(p_email),trim(p_wa),trim(p_identitas),trim(p_nomor_id),trim(p_alamat),'Normal Sale 2',p_qty,v_price,coalesce(p_holders,'[]'::jsonb))
  returning id into v_order_id;

  for i in 1..p_qty loop
    if i = 1 then
      v_name := trim(p_name); v_email := trim(p_email); v_wa := trim(p_wa);
    else
      v_name := trim(coalesce(p_holders->(i-2)->>'nama',p_name));
      v_email := trim(coalesce(p_holders->(i-2)->>'email',p_email));
      v_wa := trim(coalesce(p_holders->(i-2)->>'wa',p_wa));
    end if;
    v_code := 'CMV26-' || upper(substr(md5(gen_random_uuid()::text),1,10));
    insert into public.tickets(order_id,ticket_code,name,email,wa,ticket_type)
    values(v_order_id,v_code,v_name,v_email,v_wa,'Normal Sale 2');
    v_codes := array_append(v_codes,v_code);
  end loop;

  return query select v_order_id,v_order_code,v_codes;
end;
$$;

grant execute on function public.create_pending_order(text,text,text,text,text,text,text,integer,integer,jsonb) to anon,authenticated;

-- Payment proof submission. This does not grant the buyer any ability to mark an order PAID.
create or replace function public.submit_payment_proof(
  p_order_id uuid,
  p_storage_path text,
  p_original_filename text default null,
  p_mime_type text default null,
  p_file_size bigint default null
)
returns table(order_code text,status text)
language plpgsql
security definer
set search_path=public
as $$
declare r public.orders%rowtype;
begin
  if p_order_id is null then raise exception 'Order tidak valid'; end if;
  if p_storage_path !~ ('^' || p_order_id::text || '/[0-9a-fA-F-]{36}\.(jpg|jpeg|png)$') then raise exception 'Lokasi bukti pembayaran tidak valid'; end if;
  if p_mime_type is not null and p_mime_type not in ('image/jpeg','image/png') then raise exception 'Format bukti pembayaran tidak valid'; end if;
  if p_file_size is not null and (p_file_size < 1 or p_file_size > 10485760) then raise exception 'Ukuran bukti pembayaran tidak valid'; end if;

  select * into r from public.orders where id=p_order_id for update;
  if not found then raise exception 'Order tidak ditemukan'; end if;
  if r.status <> 'PENDING' then raise exception 'Order sudah tidak menunggu pembayaran'; end if;

  insert into public.payment_proofs(order_id,storage_path,original_filename,mime_type,file_size,submitted_by)
  values(p_order_id,p_storage_path,p_original_filename,p_mime_type,p_file_size,auth.uid());

  update public.orders
  set payment_submitted_at=now(), payment_rejected_at=null, payment_rejection_reason=null
  where id=p_order_id;

  return query select r.order_code,'PAYMENT_SUBMITTED'::text;
end;
$$;

grant execute on function public.submit_payment_proof(uuid,text,text,text,bigint) to anon,authenticated;

-- Admin approval.
create or replace function public.approve_order_payment(p_order_id uuid)
returns table(order_code text,status text,ticket_codes text[])
language plpgsql
security definer
set search_path=public
as $$
declare r public.orders%rowtype; v_codes text[];
begin
  if not public.is_admin() then raise exception 'Akses admin diperlukan'; end if;
  select * into r from public.orders where id=p_order_id for update;
  if not found then raise exception 'Order tidak ditemukan'; end if;
  if r.status='PAID' then
    select array_agg(t.ticket_code order by t.created_at) into v_codes from public.tickets t where t.order_id=p_order_id;
    return query select r.order_code,r.status,coalesce(v_codes,'{}');
  end if;
  if r.status <> 'PENDING' then raise exception 'Order tidak dapat disetujui'; end if;
  if not exists(select 1 from public.payment_proofs p where p.order_id=p_order_id) then raise exception 'Bukti pembayaran belum diunggah'; end if;

  update public.orders
  set status='PAID', paid_at=coalesce(paid_at,now()), payment_verified_at=now(),
      payment_verified_by=coalesce(auth.jwt()->>'email','admin'), payment_rejected_at=null,
      payment_rejection_reason=null
  where id=p_order_id;

  select array_agg(t.ticket_code order by t.created_at) into v_codes from public.tickets t where t.order_id=p_order_id;
  return query select r.order_code,'PAID'::text,coalesce(v_codes,'{}');
end;
$$;

grant execute on function public.approve_order_payment(uuid) to authenticated;

-- Admin rejection cancels the order so it leaves the pending queue and cannot be used as a ticket.
create or replace function public.reject_order_payment(p_order_id uuid, p_reason text default null)
returns table(order_code text,status text)
language plpgsql
security definer
set search_path=public
as $$
declare r public.orders%rowtype;
begin
  if not public.is_admin() then raise exception 'Akses admin diperlukan'; end if;
  select * into r from public.orders where id=p_order_id for update;
  if not found then raise exception 'Order tidak ditemukan'; end if;
  if r.status <> 'PENDING' then raise exception 'Order tidak dapat ditolak'; end if;

  update public.orders
  set status='CANCELLED', payment_rejected_at=now(),
      payment_rejection_reason=left(trim(coalesce(p_reason,'')),500), payment_submitted_at=null
  where id=p_order_id;

  return query select r.order_code,'CANCELLED'::text;
end;
$$;

grant execute on function public.reject_order_payment(uuid,text) to authenticated;

-- Remove the legacy client-callable payment confirmation function entirely.
drop function if exists public.confirm_order_payment(uuid);

-- Public ticket lookup. No email/WhatsApp is exposed.
drop function if exists public.get_public_ticket(text);
create function public.get_public_ticket(p_ticket_code text)
returns table(ticket_code text,name text,ticket_type text,event_date date,event_time text,location text,checked_in_at timestamptz)
language sql
security definer
set search_path=public
as $$
  select t.ticket_code,t.name,t.ticket_type,t.event_date,t.event_time,t.location,t.checked_in_at
  from public.tickets t
  join public.orders o on o.id=t.order_id
  where upper(t.ticket_code)=upper(trim(p_ticket_code)) and o.status='PAID'
  limit 1;
$$;

grant execute on function public.get_public_ticket(text) to anon,authenticated;

-- Public status lookup. Ticket codes are returned only after payment is PAID.
drop function if exists public.get_public_order_status(uuid);
create function public.get_public_order_status(p_order_id uuid)
returns table(order_code text,status text,ticket_codes text[])
language sql
security definer
set search_path=public
as $$
  select o.order_code,o.status,
    case when o.status='PAID' then coalesce((select array_agg(t.ticket_code order by t.created_at) from public.tickets t where t.order_id=o.id),'{}') else '{}' end
  from public.orders o
  where o.id=p_order_id
  limit 1;
$$;

grant execute on function public.get_public_order_status(uuid) to anon,authenticated;

-- Admin check-in.
create or replace function public.check_in_ticket(p_ticket_code text)
returns table(status text,name text,ticket_code text,checked_in_at timestamptz)
language plpgsql
security definer
set search_path=public
as $$
declare r public.tickets%rowtype;
begin
  if not public.is_admin() then raise exception 'Akses admin diperlukan'; end if;
  select t.* into r from public.tickets t join public.orders o on o.id=t.order_id
  where upper(t.ticket_code)=upper(trim(p_ticket_code)) and o.status='PAID' limit 1;
  if not found then return query select 'INVALID'::text,null::text,trim(p_ticket_code),null::timestamptz; return; end if;
  if r.checked_in_at is not null then return query select 'ALREADY_USED'::text,r.name,r.ticket_code,r.checked_in_at; return; end if;
  update public.tickets set checked_in_at=now(),checked_in_by=coalesce(auth.jwt()->>'email','admin') where id=r.id returning * into r;
  return query select 'CHECKED_IN'::text,r.name,r.ticket_code,r.checked_in_at;
end;
$$;

grant execute on function public.check_in_ticket(text) to authenticated;

create or replace function public.get_checkin_stats()
returns table(total_tickets bigint,checked_in bigint,remaining bigint)
language plpgsql
security definer
set search_path=public
as $$
begin
  if not public.is_admin() then raise exception 'Akses admin diperlukan'; end if;
  return query
  select count(*)::bigint,
         count(*) filter(where t.checked_in_at is not null)::bigint,
         count(*) filter(where t.checked_in_at is null)::bigint
  from public.tickets t join public.orders o on o.id=t.order_id
  where o.status='PAID';
end;
$$;

grant execute on function public.get_checkin_stats() to authenticated;

create or replace function public.get_pending_payment_reviews()
returns table(
  order_id uuid, order_code text, name text, email text, wa text, ticket_type text,
  qty integer, total_price integer, created_at timestamptz, payment_submitted_at timestamptz,
  proof_id uuid, storage_path text, original_filename text, mime_type text, file_size bigint,
  proof_submitted_at timestamptz
)
language plpgsql
security definer
set search_path=public
as $$
begin
  if not public.is_admin() then raise exception 'Akses admin diperlukan'; end if;
  return query
  select o.id,o.order_code,o.name,o.email,o.wa,o.ticket_type,o.qty,o.total_price,o.created_at,
         o.payment_submitted_at,p.id,p.storage_path,p.original_filename,p.mime_type,p.file_size,p.submitted_at
  from public.orders o
  join lateral (
    select pp.* from public.payment_proofs pp where pp.order_id=o.id order by pp.submitted_at desc limit 1
  ) p on true
  where o.status='PENDING'
  order by coalesce(o.payment_submitted_at,o.created_at) asc;
end;
$$;

grant execute on function public.get_pending_payment_reviews() to authenticated;

-- Direct table access remains closed; admin data is served through protected RPCs.
drop policy if exists "admin can read tickets" on public.tickets;
drop policy if exists "admins can read tickets" on public.tickets;
create policy "admins can read tickets" on public.tickets
  for select to authenticated using (public.is_admin());

drop policy if exists "admins can read payment proofs" on public.payment_proofs;
create policy "admins can read payment proofs" on public.payment_proofs
  for select to authenticated using (public.is_admin());

-- Private payment-proof bucket.
insert into storage.buckets (id,name,public)
values ('payment-proofs','payment-proofs',false)
on conflict (id) do update set public=false;

drop policy if exists "public can upload payment proofs" on storage.objects;
create policy "public can upload payment proofs" on storage.objects
  for insert to anon,authenticated
  with check (
    bucket_id='payment-proofs'
    and name ~ '^[0-9a-fA-F-]{36}/[0-9a-fA-F-]{36}\.(jpg|jpeg|png)$'
  );

drop policy if exists "admins can read payment proofs files" on storage.objects;
create policy "admins can read payment proofs files" on storage.objects
  for select to authenticated
  using (bucket_id='payment-proofs' and public.is_admin());

-- After creating an admin in Supabase Authentication, insert its UUID/email:
-- insert into public.admin_users(user_id,email) values ('AUTH-USER-UUID','admin@example.com');
