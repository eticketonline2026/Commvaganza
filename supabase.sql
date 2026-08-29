-- COMMVAGANZA 10.0 / Supabase SQL
-- Run this entire file in Supabase Dashboard -> SQL Editor.
-- IMPORTANT: never put a service_role key in HTML/JS.

create extension if not exists pgcrypto;

do $$ begin
  create type public.order_status as enum ('PENDING_PAYMENT','PROOF_SUBMITTED','PAID','CANCELLED','EXPIRED');
exception when duplicate_object then null;
end $$;

create table if not exists public.events (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique,
  name text not null,
  event_date timestamptz not null,
  venue text not null,
  created_at timestamptz not null default now()
);

create table if not exists public.ticket_types (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  code text not null,
  name text not null,
  price bigint not null check (price >= 0),
  capacity integer not null check (capacity >= 0),
  reserved_count integer not null default 0 check (reserved_count >= 0),
  sold_count integer not null default 0 check (sold_count >= 0),
  active boolean not null default true,
  unique(event_id, code)
);

create table if not exists public.orders (
  id uuid primary key default gen_random_uuid(),
  order_code text not null unique,
  event_id uuid not null references public.events(id),
  ticket_type_id uuid not null references public.ticket_types(id),
  qty integer not null check (qty between 1 and 5),
  unit_price bigint not null check (unit_price >= 0),
  total_amount bigint not null check (total_amount >= 0),
  customer_name text not null,
  customer_identity_type text not null,
  customer_identity_number text not null,
  customer_email text not null,
  customer_whatsapp text not null,
  customer_address text not null,
  status public.order_status not null default 'PENDING_PAYMENT',
  reserved_until timestamptz not null default (now() + interval '5 minutes'),
  payment_proof_path text,
  payment_proof_filename text,
  payment_proof_mime text,
  payment_proof_size bigint,
  payment_submitted_at timestamptz,
  paid_at timestamptz,
  cancelled_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.ticket_holders (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  ticket_no integer not null check (ticket_no >= 1),
  name text not null,
  email text not null,
  whatsapp text not null,
  unique(order_id, ticket_no)
);

create table if not exists public.etickets (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  ticket_holder_id uuid not null references public.ticket_holders(id) on delete cascade,
  ticket_no integer not null,
  ticket_code text not null unique,
  status text not null default 'VALID' check (status in ('VALID','USED','VOID')),
  issued_at timestamptz not null default now(),
  used_at timestamptz
);
create unique index if not exists uq_etickets_holder on public.etickets(ticket_holder_id);

create table if not exists public.admin_users (
  user_id uuid primary key references auth.users(id) on delete cascade,
  role text not null default 'admin' check (role in ('admin','superadmin')),
  created_at timestamptz not null default now()
);

-- Seed event + currently active ticket tier.
insert into public.events(slug,name,event_date,venue)
values ('commvaganza-10','Picnic Music Festival COMMVAGANZA 10.0','2026-09-12 14:00:00+07','Bandar Lampung')
on conflict (slug) do update set name=excluded.name,event_date=excluded.event_date,venue=excluded.venue;

insert into public.ticket_types(event_id,code,name,price,capacity,active)
select e.id,'NORMAL_SALE_2','Normal Sale 2',210000,100,true
from public.events e where e.slug='commvaganza-10'
on conflict (event_id,code) do update set name=excluded.name,price=excluded.price,active=excluded.active;

create index if not exists idx_orders_created_at on public.orders(created_at desc);
create index if not exists idx_orders_status on public.orders(status);
create index if not exists idx_holders_order on public.ticket_holders(order_id);
create index if not exists idx_etickets_order on public.etickets(order_id);

create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at=now(); return new; end $$;

drop trigger if exists trg_orders_updated_at on public.orders;
create trigger trg_orders_updated_at before update on public.orders
for each row execute function public.touch_updated_at();

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path=public
as $$ select exists(select 1 from public.admin_users where user_id=auth.uid()); $$;

-- Release expired reservations. Called automatically by public-facing RPCs and can also be run manually.
create or replace function public.release_expired_orders()
returns integer language plpgsql security definer set search_path=public
as $$
declare r record; n integer:=0;
begin
  for r in
    select o.id,o.ticket_type_id,o.qty
    from public.orders o
    where o.status='PENDING_PAYMENT' and o.reserved_until < now()
    for update skip locked
  loop
    update public.orders set status='EXPIRED',cancelled_at=now() where id=r.id;
    update public.ticket_types set reserved_count=greatest(0,reserved_count-r.qty) where id=r.ticket_type_id;
    n:=n+1;
  end loop;
  return n;
end $$;

-- Public availability: exposes only remaining seats and public price.
create or replace function public.get_ticket_availability(p_event_slug text,p_ticket_code text)
returns table(ticket_name text,price bigint,capacity integer,available integer)
language sql security definer set search_path=public
as $$
  select tt.name,tt.price,tt.capacity,
         greatest(0,tt.capacity-tt.sold_count-tt.reserved_count)
  from public.ticket_types tt join public.events e on e.id=tt.event_id
  where e.slug=p_event_slug and tt.code=p_ticket_code and tt.active=true;
$$;

-- Customer creates an order. Server calculates price and enforces capacity. Reservation window: 5 minutes.
create or replace function public.create_order(
  p_event_slug text,
  p_ticket_code text,
  p_qty integer,
  p_customer_name text,
  p_customer_identity_type text,
  p_customer_identity_number text,
  p_customer_email text,
  p_customer_whatsapp text,
  p_customer_address text,
  p_holders jsonb default '[]'::jsonb
)
returns table(order_id uuid,order_code text,unit_price bigint,total_amount bigint,reserved_until timestamptz)
language plpgsql security definer set search_path=public
as $$
declare ev public.events%rowtype; tt public.ticket_types%rowtype; oid uuid; ocode text; i integer;
begin
  if p_qty is null or p_qty<1 or p_qty>5 then raise exception 'Jumlah tiket harus 1-5'; end if;
  if nullif(trim(p_customer_name),'') is null then raise exception 'Nama wajib diisi'; end if;
  if nullif(trim(p_customer_identity_number),'') is null then raise exception 'Nomor identitas wajib diisi'; end if;
  if nullif(trim(p_customer_email),'') is null then raise exception 'Email wajib diisi'; end if;
  if nullif(trim(p_customer_whatsapp),'') is null then raise exception 'WhatsApp wajib diisi'; end if;
  if jsonb_typeof(coalesce(p_holders,'[]'::jsonb))<>'array' then raise exception 'Data pemegang tiket tidak valid'; end if;
  if jsonb_array_length(coalesce(p_holders,'[]'::jsonb)) <> greatest(p_qty-1,0) then raise exception 'Jumlah data pemegang tiket tidak sesuai'; end if;

  perform public.release_expired_orders();
  select * into ev from public.events where slug=p_event_slug for share;
  if not found then raise exception 'Event tidak ditemukan'; end if;
  select * into tt from public.ticket_types where event_id=ev.id and code=p_ticket_code and active=true for update;
  if not found then raise exception 'Tiket tidak tersedia'; end if;
  if tt.capacity - tt.sold_count - tt.reserved_count < p_qty then raise exception 'Kapasitas tiket tidak mencukupi'; end if;

  oid:=gen_random_uuid();
  ocode:='CMV-'||upper(substr(replace(oid::text,'-',''),1,10));

  insert into public.orders(id,order_code,event_id,ticket_type_id,qty,unit_price,total_amount,
    customer_name,customer_identity_type,customer_identity_number,customer_email,customer_whatsapp,customer_address)
  values(oid,ocode,ev.id,tt.id,p_qty,tt.price,tt.price*p_qty,trim(p_customer_name),trim(p_customer_identity_type),
    trim(p_customer_identity_number),lower(trim(p_customer_email)),trim(p_customer_whatsapp),trim(p_customer_address));

  insert into public.ticket_holders(order_id,ticket_no,name,email,whatsapp)
  values(oid,1,trim(p_customer_name),lower(trim(p_customer_email)),trim(p_customer_whatsapp));

  for i in 0..jsonb_array_length(coalesce(p_holders,'[]'::jsonb))-1 loop
    if nullif(trim(p_holders->i->>'nama'),'') is null
       or nullif(trim(p_holders->i->>'email'),'') is null
       or nullif(trim(p_holders->i->>'wa'),'') is null then
       raise exception 'Data pemegang tiket #% tidak lengkap',i+2;
    end if;
    insert into public.ticket_holders(order_id,ticket_no,name,email,whatsapp)
    values(oid,coalesce((p_holders->i->>'tiket')::int,i+2),trim(p_holders->i->>'nama'),
           lower(trim(p_holders->i->>'email')),trim(p_holders->i->>'wa'));
  end loop;

  update public.ticket_types set reserved_count=reserved_count+p_qty where id=tt.id;
  return query select oid,ocode,tt.price,tt.price*p_qty,(select reserved_until from public.orders where id=oid);
end $$;

-- Public order lookup requires both UUID and order code and returns NO identity number/address.
create or replace function public.get_public_order(p_order_id uuid,p_order_code text)
returns table(order_id uuid,order_code text,status text,qty integer,unit_price bigint,total_amount bigint,
              customer_name text,customer_email text,customer_whatsapp text,reserved_until timestamptz,paid_at timestamptz)
language plpgsql security definer set search_path=public
as $$
begin
  perform public.release_expired_orders();
  return query
  select o.id,o.order_code,o.status::text,o.qty,o.unit_price,o.total_amount,o.customer_name,o.customer_email,
         o.customer_whatsapp,o.reserved_until,o.paid_at
  from public.orders o
  where o.id=p_order_id and o.order_code=p_order_code;
end $$;

-- Customer uploads proof metadata only after a valid pending order.
create or replace function public.submit_payment_proof(
  p_order_id uuid,p_order_code text,p_storage_path text,p_original_filename text,p_mime_type text,p_file_size bigint
)
returns table(order_id uuid,status text)
language plpgsql security definer set search_path=public
as $$
declare o public.orders%rowtype;
begin
  select * into o from public.orders where id=p_order_id and order_code=p_order_code for update;
  if not found then raise exception 'Pesanan tidak ditemukan'; end if;
  if o.status<>'PENDING_PAYMENT' then raise exception 'Pesanan tidak lagi menunggu pembayaran'; end if;
  if o.reserved_until<now() then
    update public.orders set status='EXPIRED',cancelled_at=now() where id=o.id;
    update public.ticket_types set reserved_count=greatest(0,reserved_count-o.qty) where id=o.ticket_type_id;
    raise exception 'Waktu pembayaran sudah habis';
  end if;
  if p_mime_type not in ('image/jpeg','image/png') then raise exception 'Format bukti tidak valid'; end if;
  if p_file_size is null or p_file_size<=0 or p_file_size>10485760 then raise exception 'Ukuran bukti tidak valid'; end if;
  if p_storage_path not like p_order_id::text||'/%' then raise exception 'Path bukti tidak valid'; end if;

  update public.orders set status='PROOF_SUBMITTED',payment_proof_path=p_storage_path,
    payment_proof_filename=left(p_original_filename,255),payment_proof_mime=p_mime_type,
    payment_proof_size=p_file_size,payment_submitted_at=now()
  where id=o.id;
  return query select o.id,'PROOF_SUBMITTED';
end $$;

-- Admin list.
create or replace function public.admin_list_orders(p_status text default null)
returns setof public.orders
language plpgsql security definer set search_path=public
as $$
begin
  if not public.is_admin() then raise exception 'Akses admin ditolak'; end if;
  return query
  select o.* from public.orders o
  where p_status is null or o.status::text=p_status
  order by o.created_at desc;
end $$;

create or replace function public.admin_order_holders(p_order_id uuid)
returns setof public.ticket_holders
language plpgsql security definer set search_path=public
as $$
begin
  if not public.is_admin() then raise exception 'Akses admin ditolak'; end if;
  return query select h.* from public.ticket_holders h where h.order_id=p_order_id order by h.ticket_no;
end $$;

-- Approve/reject with inventory integrity.
create or replace function public.admin_set_order_status(p_order_id uuid,p_action text)
returns table(order_id uuid,status text)
language plpgsql security definer set search_path=public
as $$
declare o public.orders%rowtype; h public.ticket_holders%rowtype; c text;
begin
  if not public.is_admin() then raise exception 'Akses admin ditolak'; end if;
  select * into o from public.orders where id=p_order_id for update;
  if not found then raise exception 'Order tidak ditemukan'; end if;

  if p_action='APPROVE' then
    if o.status<>'PROOF_SUBMITTED' then raise exception 'Order harus memiliki bukti pembayaran sebelum disetujui'; end if;
    update public.ticket_types set reserved_count=greatest(0,reserved_count-o.qty),sold_count=sold_count+o.qty where id=o.ticket_type_id;
    update public.orders set status='PAID',paid_at=now() where id=o.id;
    for h in select * from public.ticket_holders where order_id=o.id order by ticket_no loop
      c:='CMV-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,12));
      insert into public.etickets(order_id,ticket_holder_id,ticket_no,ticket_code) values(o.id,h.id,h.ticket_no,c)
      on conflict (ticket_holder_id) do nothing;
    end loop;
  elsif p_action='REJECT' then
    if o.status<>'PROOF_SUBMITTED' then raise exception 'Hanya bukti yang sudah dikirim yang dapat ditolak'; end if;
    update public.orders set status='CANCELLED',cancelled_at=now() where id=o.id;
    update public.ticket_types set reserved_count=greatest(0,reserved_count-o.qty) where id=o.ticket_type_id;
  elsif p_action='CANCEL' then
    if o.status in ('PENDING_PAYMENT','PROOF_SUBMITTED') then
      update public.orders set status='CANCELLED',cancelled_at=now() where id=o.id;
      update public.ticket_types set reserved_count=greatest(0,reserved_count-o.qty) where id=o.ticket_type_id;
    else raise exception 'Order tidak dapat dibatalkan'; end if;
  else raise exception 'Aksi admin tidak valid'; end if;

  return query select o.id,(select status::text from public.orders where id=o.id);
end $$;

create or replace function public.admin_get_etickets(p_order_id uuid)
returns table(ticket_no integer,ticket_code text,holder_name text,holder_email text,holder_whatsapp text,status text)
language plpgsql security definer set search_path=public
as $$
begin
  if not public.is_admin() then raise exception 'Akses admin ditolak'; end if;
  return query
  select e.ticket_no,e.ticket_code,h.name,h.email,h.whatsapp,e.status
  from public.etickets e join public.ticket_holders h on h.id=e.ticket_holder_id
  where e.order_id=p_order_id order by e.ticket_no;
end $$;

-- Public e-ticket lookup. It reveals only ticket-holder names and ticket codes after payment.
create or replace function public.get_public_etickets(p_order_id uuid,p_order_code text)
returns table(order_code text,status text,event_name text,event_date timestamptz,venue text,
              ticket_no integer,ticket_code text,holder_name text,ticket_status text)
language plpgsql security definer set search_path=public
as $$
begin
  return query
  select o.order_code,o.status::text,ev.name,ev.event_date,ev.venue,e.ticket_no,e.ticket_code,h.name,e.status
  from public.orders o join public.events ev on ev.id=o.event_id
  join public.etickets e on e.order_id=o.id join public.ticket_holders h on h.id=e.ticket_holder_id
  where o.id=p_order_id and o.order_code=p_order_code and o.status='PAID'
  order by e.ticket_no;
end $$;

-- Explicit RPC privileges.
grant execute on function public.get_ticket_availability(text,text) to anon,authenticated;
grant execute on function public.create_order(text,text,integer,text,text,text,text,text,text,jsonb) to anon,authenticated;
grant execute on function public.get_public_order(uuid,text) to anon,authenticated;
grant execute on function public.submit_payment_proof(uuid,text,text,text,text,bigint) to anon,authenticated;
grant execute on function public.get_public_etickets(uuid,text) to anon,authenticated;
grant execute on function public.admin_list_orders(text) to authenticated;
grant execute on function public.admin_order_holders(uuid) to authenticated;
grant execute on function public.admin_set_order_status(uuid,text) to authenticated;
grant execute on function public.admin_get_etickets(uuid) to authenticated;
grant execute on function public.is_admin() to authenticated;

-- RLS: browser clients do not get direct table access. RPCs are the public API.
alter table public.events enable row level security;
alter table public.ticket_types enable row level security;
alter table public.orders enable row level security;
alter table public.ticket_holders enable row level security;
alter table public.etickets enable row level security;
alter table public.admin_users enable row level security;

-- Explicitly deny direct anon/authenticated table reads/writes by providing no policies.
-- SECURITY DEFINER functions above are the intended API surface.

-- Storage bucket for payment proofs (PRIVATE).
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('payment-proofs','payment-proofs',false,10485760,array['image/jpeg','image/png'])
on conflict(id) do update set public=false,file_size_limit=10485760,allowed_mime_types=array['image/jpeg','image/png'];

-- Anonymous customer upload: object path must begin with a UUID-like order folder.
drop policy if exists "payment proof anon insert" on storage.objects;
create policy "payment proof anon insert" on storage.objects
for insert to anon
with check (
  bucket_id='payment-proofs'
  and (storage.foldername(name))[1] ~ '^[0-9a-fA-F-]{36}$'
);

-- Admin can read/delete proof files after login.
drop policy if exists "payment proof admin select" on storage.objects;
create policy "payment proof admin select" on storage.objects
for select to authenticated
using (bucket_id='payment-proofs' and public.is_admin());

drop policy if exists "payment proof admin delete" on storage.objects;
create policy "payment proof admin delete" on storage.objects
for delete to authenticated
using (bucket_id='payment-proofs' and public.is_admin());

-- Realtime is optional; dashboard polls, so no publication changes are required.
