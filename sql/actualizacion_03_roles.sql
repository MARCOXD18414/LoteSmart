-- =====================================================================
--  LoteSmart · Actualización 03: roles de usuario
--  NO borra datos. Ejecútalo una vez en Supabase → SQL Editor → Run.
--
--  · Roles: Administrador, Almacén, Vendedor y Consulta, con sus permisos.
--  · Cada cuenta recibe su perfil. La cuenta más antigua queda como
--    Administrador; las demás como Consulta (el administrador las cambia
--    desde la pantalla Usuarios de la app).
--  · Todas las funciones validan el permiso del usuario antes de operar.
-- =====================================================================

-- ---------- Roles y permisos (control de acceso por rol) ----------
create table if not exists rol (
  id_rol      smallint generated always as identity primary key,
  clave       varchar(20)  not null,
  nombre      varchar(40)  not null,
  descripcion varchar(200),
  constraint uq_rol_clave unique (clave),
  constraint ck_rol_clave check (clave = upper(clave))
);

create table if not exists permiso (
  clave       varchar(40)  primary key,
  descripcion varchar(120) not null,
  orden       smallint     not null default 0
);

create table if not exists rol_permiso (
  id_rol   smallint    not null references rol(id_rol) on delete cascade,
  permiso  varchar(40) not null references permiso(clave) on delete cascade,
  primary key (id_rol, permiso)
);

-- Perfil de cada cuenta de Supabase Auth dentro de LoteSmart.
create table if not exists usuario (
  id_usuario int generated always as identity primary key,
  auth_id    uuid         not null,
  email      varchar(160) not null,
  nombre     varchar(80)  not null,
  id_rol     smallint     not null references rol(id_rol) on delete restrict,
  activo     boolean      not null default true,
  creado_en  timestamptz  not null default now(),
  constraint uq_usuario_auth unique (auth_id),
  constraint ck_usuario_nombre check (char_length(trim(nombre)) >= 2)
);
create index if not exists ix_usuario_rol on usuario (id_rol);

insert into rol (clave, nombre, descripcion) values
  ('ADMIN',    'Administrador', 'Todo, incluida la administración de usuarios y permisos.'),
  ('ALMACEN',  'Almacén',       'Productos, proveedores, entradas de lotes, mermas y ajustes.'),
  ('VENDEDOR', 'Vendedor',      'Registra ventas con FEFO y da de alta clientes.'),
  ('CONSULTA', 'Consulta',      'Solo puede ver la información y los reportes.')
on conflict (clave) do nothing;

insert into permiso (clave, descripcion, orden) values
  ('catalogo.editar',       'Dar de alta, modificar y dar de baja productos y proveedores', 1),
  ('clientes.editar',       'Dar de alta, modificar y dar de baja clientes', 2),
  ('lotes.editar',          'Registrar entradas de lotes, corregirlos y bloquearlos', 3),
  ('inventario.ajustar',    'Registrar mermas y ajustes de inventario', 4),
  ('ventas.registrar',      'Registrar ventas', 5),
  ('ventas.cancelar',       'Cancelar ventas', 6),
  ('registros.eliminar',    'Eliminar registros de forma definitiva', 7),
  ('reportes.ver',          'Ver y exportar reportes', 8),
  ('auditoria.ver',         'Ver la auditoría', 9),
  ('usuarios.administrar',  'Administrar usuarios, roles y permisos', 10)
on conflict (clave) do nothing;

insert into rol_permiso (id_rol, permiso)
select r.id_rol, p.clave from rol r cross join permiso p
 where r.clave = 'ADMIN'
    or (r.clave = 'ALMACEN'  and p.clave in ('catalogo.editar', 'lotes.editar', 'inventario.ajustar', 'reportes.ver'))
    or (r.clave = 'VENDEDOR' and p.clave in ('clientes.editar', 'ventas.registrar', 'reportes.ver'))
    or (r.clave = 'CONSULTA' and p.clave in ('reportes.ver'))
on conflict do nothing;


create or replace function fn_uid() returns uuid language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claim.sub', true), ''),
                  nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')::uuid
$$;

create or replace function fn_usuario() returns text language plpgsql stable security definer set search_path = public as $$
declare v text; c jsonb := nullif(current_setting('request.jwt.claims', true), '')::jsonb;
begin
  if fn_uid() is not null and to_regclass('public.usuario') is not null then
    execute 'select nombre from usuario where auth_id = $1' into v using fn_uid();
  end if;
  return left(coalesce(v, nullif(c -> 'user_metadata' ->> 'nombre', ''), nullif(c ->> 'email', ''),
                       nullif(current_setting('app.usuario', true), ''), session_user::text), 120);
end $$;

create or replace function fn_activo() returns boolean language plpgsql stable security definer set search_path = public as $$
begin
  if fn_uid() is null then
    return coalesce(current_setting('role', true), 'none') not in ('anon', 'authenticated');
  end if;
  return exists (select 1 from usuario where auth_id = fn_uid() and activo);
end $$;

create or replace function fn_tiene_permiso(p_permiso text) returns boolean language plpgsql stable security definer set search_path = public as $$
begin
  if fn_uid() is null then
    return coalesce(current_setting('role', true), 'none') not in ('anon', 'authenticated');
  end if;
  return exists (select 1 from usuario u join rol_permiso rp on rp.id_rol = u.id_rol
                  where u.auth_id = fn_uid() and u.activo and rp.permiso = p_permiso);
end $$;

create or replace function fn_exigir(p_permiso text) returns void language plpgsql stable security definer set search_path = public as $$
declare v_activo boolean; v_rol text; v_desc text;
begin
  if fn_uid() is null then
    if coalesce(current_setting('role', true), 'none') in ('anon', 'authenticated') then
      raise exception 'Inicia sesión para continuar.' using errcode = 'P0001';
    end if;
    return;   -- SQL Editor / instalación
  end if;
  select u.activo, r.nombre into v_activo, v_rol from usuario u join rol r on r.id_rol = u.id_rol where u.auth_id = fn_uid();
  if not found then
    raise exception 'Tu cuenta aún no tiene perfil en LoteSmart. Cierra sesión y vuelve a entrar.' using errcode = 'P0001';
  end if;
  if not v_activo then
    raise exception 'Tu usuario está desactivado. Habla con un administrador.' using errcode = 'P0001';
  end if;
  if p_permiso is not null and not exists (
       select 1 from usuario u join rol_permiso rp on rp.id_rol = u.id_rol where u.auth_id = fn_uid() and rp.permiso = p_permiso) then
    select descripcion into v_desc from permiso where clave = p_permiso;
    raise exception 'Tu rol (%) no tiene permiso para: %.', v_rol, lower(coalesce(v_desc, p_permiso)) using errcode = 'P0001';
  end if;
end $$;

create or replace function fn_hoy() returns date language sql stable as
$$ select (now() at time zone 'America/Mexico_City')::date $$;

create or replace function fn_set_usuario(p_usuario text) returns void language sql as
$$ select set_config('app.usuario', coalesce(nullif(trim(p_usuario), ''), 'web'), true) $$;

create or replace function fn_interno() returns boolean language sql stable as
$$ select coalesce(current_setting('lotesmart.interno', true), '') = '1' $$;

create or replace function fn_estado_lote(p_actual estado_lote, p_disp int, p_cad date)
returns estado_lote language sql stable as $$
  select case
    when p_actual = 'BLOQUEADO'  then 'BLOQUEADO'::estado_lote
    when p_cad < fn_hoy()        then 'CADUCADO'::estado_lote
    when p_disp = 0              then 'AGOTADO'::estado_lote
    else 'VIGENTE'::estado_lote end
$$;

create or replace function fn_folio(p_id bigint) returns text language sql immutable as
$$ select 'V-' || lpad(p_id::text, 6, '0') $$;

create or replace function trg_catalogo_bi() returns trigger language plpgsql as $$
begin
  if tg_table_name = 'producto' then
    new.sku := upper(trim(new.sku));  new.nombre := trim(new.nombre);
  elsif tg_table_name = 'proveedor' then
    new.rfc := upper(trim(new.rfc));  new.nombre := trim(new.nombre);
    new.telefono := nullif(trim(new.telefono), '');
  elsif tg_table_name = 'cliente' then
    new.nombre := trim(new.nombre);   new.rfc := nullif(upper(trim(new.rfc)), '');
    new.telefono := nullif(trim(new.telefono), ''); new.correo := nullif(lower(trim(new.correo)), '');
  end if;
  return new;
end $$;

create or replace function trg_producto_bd() returns trigger language plpgsql as $$
begin
  if exists (select 1 from lote where id_producto = old.id_producto) then
    raise exception 'El producto "%" tiene lotes registrados. Use la baja lógica.', old.nombre using errcode = 'P0001';
  end if;
  return old;
end $$;

create or replace function trg_proveedor_bd() returns trigger language plpgsql as $$
begin
  if exists (select 1 from lote where id_proveedor = old.id_proveedor) then
    raise exception 'El proveedor "%" ya entregó lotes. Use la baja lógica.', old.nombre using errcode = 'P0001';
  end if;
  return old;
end $$;

create or replace function trg_cliente_bd() returns trigger language plpgsql as $$
begin
  if exists (select 1 from venta where id_cliente = old.id_cliente) then
    raise exception 'El cliente "%" tiene ventas registradas. Use la baja lógica.', old.nombre using errcode = 'P0001';
  end if;
  return old;
end $$;

create or replace function trg_lote_bi() returns trigger language plpgsql as $$
begin
  if coalesce(current_setting('lotesmart.seed', true), '') <> '1' then
    if new.fecha_caducidad <= fn_hoy() then
      raise exception 'La caducidad debe ser posterior a hoy (%).', to_char(fn_hoy(), 'DD/MM/YYYY') using errcode = 'P0001';
    end if;
  end if;
  if not exists (select 1 from producto where id_producto = new.id_producto and activo) then
    raise exception 'El producto está dado de baja; no puede recibir lotes nuevos.' using errcode = 'P0001';
  end if;
  if not exists (select 1 from proveedor where id_proveedor = new.id_proveedor and activo) then
    raise exception 'El proveedor está dado de baja; no puede entregar lotes.' using errcode = 'P0001';
  end if;
  new.codigo_lote := upper(trim(new.codigo_lote));
  new.cantidad_disponible := new.cantidad_inicial;
  new.motivo_bloqueo := null;
  new.estado := fn_estado_lote('VIGENTE', new.cantidad_disponible, new.fecha_caducidad);
  return new;
end $$;

create or replace function trg_lote_bu() returns trigger language plpgsql as $$
declare v_con_mov boolean;
begin
  new.codigo_lote := upper(trim(new.codigo_lote));
  select exists (select 1 from movimiento where id_lote = old.id_lote) into v_con_mov;

  if (new.cantidad_inicial, new.costo_unitario, new.id_producto)
     is distinct from (old.cantidad_inicial, old.costo_unitario, old.id_producto) then
    if v_con_mov then
      raise exception 'El lote % ya tiene movimientos: cantidad, costo y producto ya no se pueden corregir. Use un ajuste.', old.codigo_lote using errcode = 'P0001';
    end if;
    if new.id_producto <> old.id_producto and not exists (select 1 from producto where id_producto = new.id_producto and activo) then
      raise exception 'El producto elegido está dado de baja.' using errcode = 'P0001';
    end if;
    new.cantidad_disponible := new.cantidad_inicial;  -- sin movimientos, disponible = recibido
  elsif new.cantidad_disponible <> old.cantidad_disponible and not fn_interno() then
    raise exception 'La existencia de un lote no se edita: solo cambia con ventas, mermas, ajustes o devoluciones.' using errcode = 'P0001';
  end if;

  if new.id_proveedor <> old.id_proveedor and not exists (select 1 from proveedor where id_proveedor = new.id_proveedor and activo) then
    raise exception 'El proveedor elegido está dado de baja.' using errcode = 'P0001';
  end if;

  if new.fecha_caducidad <> old.fecha_caducidad and new.fecha_caducidad <= fn_hoy() and not fn_interno() then
    raise exception 'La nueva caducidad debe ser posterior a hoy.' using errcode = 'P0001';
  end if;

  if (new.estado <> old.estado or new.motivo_bloqueo is distinct from old.motivo_bloqueo) and not fn_interno() then
    raise exception 'El estado del lote no se cambia a mano: use bloquear / desbloquear.' using errcode = 'P0001';
  end if;

  -- Recalcula el estado si cambió algo que lo determina.
  if new.estado = old.estado then
    new.estado := fn_estado_lote(new.estado, new.cantidad_disponible, new.fecha_caducidad);
  end if;
  return new;
end $$;

create or replace function trg_lote_bd() returns trigger language plpgsql as $$
begin
  if exists (select 1 from movimiento where id_lote = old.id_lote) then
    raise exception 'El lote % tiene movimientos y no se puede eliminar. Puede bloquearlo.', old.codigo_lote using errcode = 'P0001';
  end if;
  return old;
end $$;

create or replace function trg_mov_bi() returns trigger language plpgsql as $$
declare l lote%rowtype;
begin
  select * into l from lote where id_lote = new.id_lote;
  new.usuario := fn_usuario();
  new.fecha   := now();
  new.motivo  := nullif(trim(new.motivo), '');

  if new.tipo in ('MERMA','AJUSTE_NEGATIVO','AJUSTE_POSITIVO') and new.motivo is null then
    raise exception 'Las mermas y ajustes requieren un motivo.' using errcode = 'P0001';
  end if;
  if new.tipo = 'VENTA' and (l.estado <> 'VIGENTE' or l.fecha_caducidad < fn_hoy()) then
    raise exception 'El lote % no se puede vender: está %.', l.codigo_lote, l.estado using errcode = 'P0001';
  end if;
  if new.tipo in ('VENTA','MERMA','AJUSTE_NEGATIVO') and new.cantidad > l.cantidad_disponible then
    raise exception 'El lote % solo tiene % unidades disponibles.', l.codigo_lote, l.cantidad_disponible using errcode = 'P0001';
  end if;
  if new.tipo in ('AJUSTE_POSITIVO','DEVOLUCION') and l.cantidad_disponible + new.cantidad > l.cantidad_inicial then
    raise exception 'El lote % no puede tener más de lo recibido (%).', l.codigo_lote, l.cantidad_inicial using errcode = 'P0001';
  end if;
  return new;
end $$;

create or replace function trg_mov_ai() returns trigger language plpgsql as $$
declare v_delta int;
begin
  v_delta := case when new.tipo in ('VENTA','MERMA','AJUSTE_NEGATIVO') then -new.cantidad else new.cantidad end;
  perform set_config('lotesmart.interno', '1', true);
  update lote
     set cantidad_disponible = cantidad_disponible + v_delta,
         estado = fn_estado_lote(estado, cantidad_disponible + v_delta, fecha_caducidad)
   where id_lote = new.id_lote;
  perform set_config('lotesmart.interno', '0', true);
  return null;
end $$;

create or replace function trg_mov_inmutable() returns trigger language plpgsql as $$
begin
  raise exception 'Los movimientos no se editan ni se borran: registre un movimiento compensatorio.' using errcode = 'P0001';
end $$;

create or replace function trg_venta_bu() returns trigger language plpgsql as $$
begin
  if old.estado = 'CANCELADA' then
    raise exception 'La venta % ya estaba cancelada.', fn_folio(old.id_venta) using errcode = 'P0001';
  end if;
  if (new.id_cliente, new.fecha, new.usuario) is distinct from (old.id_cliente, old.fecha, old.usuario) then
    raise exception 'Una venta registrada no se modifica: cancélela y registre otra.' using errcode = 'P0001';
  end if;
  if new.estado = 'CANCELADA' then
    new.motivo_cancelacion := nullif(trim(new.motivo_cancelacion), '');
    if new.motivo_cancelacion is null then
      raise exception 'Escriba el motivo de la cancelación.' using errcode = 'P0001';
    end if;
    new.fecha_cancelacion := now();
  end if;
  return new;
end $$;

create or replace function trg_venta_bd() returns trigger language plpgsql as $$
begin
  raise exception 'Las ventas no se eliminan: se cancelan con motivo.' using errcode = 'P0001';
end $$;

create or replace function trg_auditar() returns trigger language plpgsql as $$
declare
  v_pk text := tg_argv[0];
  v_old jsonb; v_new jsonb; v_id bigint; v_accion text; v_det text := ''; k text;
begin
  if tg_op = 'INSERT' then
    v_new := to_jsonb(new); v_id := (v_new->>v_pk)::bigint; v_accion := 'ALTA';
    select left(string_agg(key || ': ' || value, '; '), 500) into v_det
      from jsonb_each_text(v_new) where value is not null and key not in (v_pk, 'creado_en', 'fecha_entrada', 'fecha', 'usuario');
  elsif tg_op = 'DELETE' then
    v_old := to_jsonb(old); v_id := (v_old->>v_pk)::bigint; v_accion := 'ELIMINACION';
    select left(string_agg(key || ': ' || value, '; '), 500) into v_det
      from jsonb_each_text(v_old) where value is not null and key not in (v_pk, 'creado_en', 'fecha_entrada', 'fecha', 'usuario');
  else
    v_old := to_jsonb(old); v_new := to_jsonb(new); v_id := (v_new->>v_pk)::bigint;
    for k in select jsonb_object_keys(v_new) loop
      if k <> 'cantidad_disponible' and (v_old->k) is distinct from (v_new->k) then
        v_det := v_det || k || ': ' || coalesce(v_old->>k, '∅') || ' → ' || coalesce(v_new->>k, '∅') || '; ';
      end if;
    end loop;
    if v_det = '' then return null; end if;  -- solo cambió la existencia (ya queda en movimiento)
    v_accion := case
      when v_old ? 'activo' and (v_old->>'activo')::boolean and not (v_new->>'activo')::boolean then 'BAJA'
      when v_old ? 'activo' and not (v_old->>'activo')::boolean and (v_new->>'activo')::boolean then 'REACTIVACION'
      when tg_table_name = 'venta' and v_new->>'estado' = 'CANCELADA' then 'CANCELACION'
      when tg_table_name = 'lote'  and (v_old->>'estado') <> (v_new->>'estado') then 'CAMBIO_ESTADO'
      else 'MODIFICACION' end;
    v_det := left(v_det, 500);
  end if;
  insert into auditoria (tabla, id_registro, accion, detalle) values (tg_table_name, v_id, v_accion, v_det);
  return null;
end $$;

create or replace function unidad_guardar(p_clave text, p_nombre text, p_usuario text default null)
returns smallint language plpgsql security definer set search_path = public as $$
declare v_id smallint;
begin
  perform fn_set_usuario(p_usuario); perform fn_exigir('catalogo.editar');
  insert into unidad_medida (clave, nombre) values (upper(trim(p_clave)), trim(p_nombre)) returning id_unidad into v_id;
  return v_id;
end $$;

create or replace function producto_guardar(p_id int, p_sku text, p_nombre text, p_id_unidad int,
  p_precio_venta numeric, p_stock_minimo int, p_dias_minimos_venta int, p_usuario text default null)
returns int language plpgsql security definer set search_path = public as $$
declare v_id int;
begin
  perform fn_set_usuario(p_usuario); perform fn_exigir('catalogo.editar');
  if p_id is null then
    insert into producto (sku, nombre, id_unidad, precio_venta, stock_minimo, dias_minimos_venta)
    values (p_sku, p_nombre, p_id_unidad, p_precio_venta, coalesce(p_stock_minimo, 0), coalesce(p_dias_minimos_venta, 0))
    returning id_producto into v_id;
  else
    update producto set sku = p_sku, nombre = p_nombre, id_unidad = p_id_unidad, precio_venta = p_precio_venta,
           stock_minimo = coalesce(p_stock_minimo, 0), dias_minimos_venta = coalesce(p_dias_minimos_venta, 0)
     where id_producto = p_id returning id_producto into v_id;
    if v_id is null then raise exception 'El producto no existe.' using errcode = 'P0001'; end if;
  end if;
  return v_id;
end $$;

create or replace function producto_imagen(p_id int, p_imagen_path text, p_usuario text default null) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform fn_set_usuario(p_usuario); perform fn_exigir('catalogo.editar');
  if p_imagen_path is not null and p_imagen_path !~ '^[A-Za-z0-9._/-]{3,200}$' then
    raise exception 'Nombre de archivo de imagen no válido.' using errcode = 'P0001';
  end if;
  update producto set imagen_path = p_imagen_path where id_producto = p_id;
  if not found then raise exception 'El producto no existe.' using errcode = 'P0001'; end if;
end $$;

create or replace function producto_baja(p_id int, p_usuario text default null) returns void
language plpgsql security definer set search_path = public as $$
begin perform fn_set_usuario(p_usuario); perform fn_exigir('catalogo.editar'); update producto set activo = false where id_producto = p_id; end $$;

create or replace function producto_reactivar(p_id int, p_usuario text default null) returns void
language plpgsql security definer set search_path = public as $$
begin perform fn_set_usuario(p_usuario); perform fn_exigir('catalogo.editar'); update producto set activo = true where id_producto = p_id; end $$;

create or replace function producto_eliminar(p_id int, p_usuario text default null) returns void
language plpgsql security definer set search_path = public as $$
begin perform fn_set_usuario(p_usuario); perform fn_exigir('registros.eliminar'); delete from producto where id_producto = p_id; end $$;

create or replace function proveedor_guardar(p_id int, p_rfc text, p_nombre text, p_telefono text, p_usuario text default null)
returns int language plpgsql security definer set search_path = public as $$
declare v_id int;
begin
  perform fn_set_usuario(p_usuario); perform fn_exigir('catalogo.editar');
  if p_id is null then
    insert into proveedor (rfc, nombre, telefono) values (p_rfc, p_nombre, p_telefono) returning id_proveedor into v_id;
  else
    update proveedor set rfc = p_rfc, nombre = p_nombre, telefono = p_telefono
     where id_proveedor = p_id returning id_proveedor into v_id;
    if v_id is null then raise exception 'El proveedor no existe.' using errcode = 'P0001'; end if;
  end if;
  return v_id;
end $$;

create or replace function proveedor_baja(p_id int, p_usuario text default null) returns void
language plpgsql security definer set search_path = public as $$
begin perform fn_set_usuario(p_usuario); perform fn_exigir('catalogo.editar'); update proveedor set activo = false where id_proveedor = p_id; end $$;

create or replace function proveedor_reactivar(p_id int, p_usuario text default null) returns void
language plpgsql security definer set search_path = public as $$
begin perform fn_set_usuario(p_usuario); perform fn_exigir('catalogo.editar'); update proveedor set activo = true where id_proveedor = p_id; end $$;

create or replace function proveedor_eliminar(p_id int, p_usuario text default null) returns void
language plpgsql security definer set search_path = public as $$
begin perform fn_set_usuario(p_usuario); perform fn_exigir('registros.eliminar'); delete from proveedor where id_proveedor = p_id; end $$;

create or replace function cliente_guardar(p_id int, p_nombre text, p_rfc text, p_telefono text, p_correo text, p_usuario text default null)
returns int language plpgsql security definer set search_path = public as $$
declare v_id int;
begin
  perform fn_set_usuario(p_usuario); perform fn_exigir('clientes.editar');
  if p_id is null then
    insert into cliente (nombre, rfc, telefono, correo) values (p_nombre, p_rfc, p_telefono, p_correo) returning id_cliente into v_id;
  else
    update cliente set nombre = p_nombre, rfc = p_rfc, telefono = p_telefono, correo = p_correo
     where id_cliente = p_id returning id_cliente into v_id;
    if v_id is null then raise exception 'El cliente no existe.' using errcode = 'P0001'; end if;
  end if;
  return v_id;
end $$;

create or replace function cliente_baja(p_id int, p_usuario text default null) returns void
language plpgsql security definer set search_path = public as $$
begin perform fn_set_usuario(p_usuario); perform fn_exigir('clientes.editar'); update cliente set activo = false where id_cliente = p_id; end $$;

create or replace function cliente_reactivar(p_id int, p_usuario text default null) returns void
language plpgsql security definer set search_path = public as $$
begin perform fn_set_usuario(p_usuario); perform fn_exigir('clientes.editar'); update cliente set activo = true where id_cliente = p_id; end $$;

create or replace function cliente_eliminar(p_id int, p_usuario text default null) returns void
language plpgsql security definer set search_path = public as $$
begin perform fn_set_usuario(p_usuario); perform fn_exigir('registros.eliminar'); delete from cliente where id_cliente = p_id; end $$;

create or replace function lote_alta(p_id_producto int, p_id_proveedor int, p_codigo_lote text, p_fecha_caducidad date,
  p_cantidad int, p_costo_unitario numeric, p_usuario text default null)
returns int language plpgsql security definer set search_path = public as $$
declare v_id int;
begin
  perform fn_set_usuario(p_usuario); perform fn_exigir('lotes.editar');
  insert into lote (id_producto, id_proveedor, codigo_lote, fecha_caducidad, cantidad_inicial, cantidad_disponible, costo_unitario)
  values (p_id_producto, p_id_proveedor, p_codigo_lote, p_fecha_caducidad, p_cantidad, p_cantidad, p_costo_unitario)
  returning id_lote into v_id;
  return v_id;
end $$;

create or replace function lote_modificar(p_id int, p_id_producto int, p_id_proveedor int, p_codigo_lote text,
  p_fecha_caducidad date, p_cantidad int, p_costo_unitario numeric, p_usuario text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform fn_set_usuario(p_usuario); perform fn_exigir('lotes.editar');
  update lote set id_producto = p_id_producto, id_proveedor = p_id_proveedor, codigo_lote = p_codigo_lote,
         fecha_caducidad = p_fecha_caducidad, cantidad_inicial = p_cantidad, costo_unitario = p_costo_unitario
   where id_lote = p_id;
  if not found then raise exception 'El lote no existe.' using errcode = 'P0001'; end if;
end $$;

create or replace function lote_bloquear(p_id int, p_motivo text, p_usuario text default null) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform fn_set_usuario(p_usuario); perform fn_exigir('lotes.editar');
  if nullif(trim(p_motivo), '') is null then
    raise exception 'Escriba el motivo del bloqueo.' using errcode = 'P0001';
  end if;
  if exists (select 1 from lote where id_lote = p_id and estado = 'BLOQUEADO') then
    raise exception 'El lote ya está bloqueado.' using errcode = 'P0001';
  end if;
  perform set_config('lotesmart.interno', '1', true);
  update lote set estado = 'BLOQUEADO', motivo_bloqueo = trim(p_motivo) where id_lote = p_id;
  perform set_config('lotesmart.interno', '0', true);
end $$;

create or replace function lote_desbloquear(p_id int, p_usuario text default null) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform fn_set_usuario(p_usuario); perform fn_exigir('lotes.editar');
  if not exists (select 1 from lote where id_lote = p_id and estado = 'BLOQUEADO') then
    raise exception 'El lote no está bloqueado.' using errcode = 'P0001';
  end if;
  perform set_config('lotesmart.interno', '1', true);
  update lote set estado = fn_estado_lote('VIGENTE', cantidad_disponible, fecha_caducidad), motivo_bloqueo = null
   where id_lote = p_id;
  perform set_config('lotesmart.interno', '0', true);
end $$;

create or replace function lote_eliminar(p_id int, p_usuario text default null) returns void
language plpgsql security definer set search_path = public as $$
begin perform fn_set_usuario(p_usuario); perform fn_exigir('registros.eliminar'); delete from lote where id_lote = p_id; end $$;

create or replace function registrar_merma(p_id_lote int, p_cantidad int, p_motivo text, p_usuario text default null)
returns bigint language plpgsql security definer set search_path = public as $$
declare v_id bigint;
begin
  perform fn_set_usuario(p_usuario); perform fn_exigir('inventario.ajustar');
  perform 1 from lote where id_lote = p_id_lote for update;
  insert into movimiento (id_lote, tipo, cantidad, motivo) values (p_id_lote, 'MERMA', p_cantidad, p_motivo)
  returning id_movimiento into v_id;
  return v_id;
end $$;

create or replace function registrar_ajuste(p_id_lote int, p_positivo boolean, p_cantidad int, p_motivo text, p_usuario text default null)
returns bigint language plpgsql security definer set search_path = public as $$
declare v_id bigint;
begin
  perform fn_set_usuario(p_usuario); perform fn_exigir('inventario.ajustar');
  perform 1 from lote where id_lote = p_id_lote for update;
  insert into movimiento (id_lote, tipo, cantidad, motivo)
  values (p_id_lote, case when p_positivo then 'AJUSTE_POSITIVO' else 'AJUSTE_NEGATIVO' end::tipo_movimiento, p_cantidad, p_motivo)
  returning id_movimiento into v_id;
  return v_id;
end $$;

create or replace function fn_fefo_asignar(p_id_producto int, p_cantidad int, p_bloquear boolean)
returns table (id_lote int, codigo_lote text, fecha_caducidad date, tomar int)
language plpgsql as $$
declare
  v_prod producto%rowtype; v_min date; v_rest int := p_cantidad; v_vendibles int := 0; r record; v_tomar int;
begin
  if p_cantidad is null or p_cantidad <= 0 then
    raise exception 'La cantidad debe ser mayor que cero.' using errcode = 'P0001';
  end if;
  select * into v_prod from producto where producto.id_producto = p_id_producto;
  if not found then raise exception 'El producto no existe.' using errcode = 'P0001'; end if;
  v_min := fn_hoy() + v_prod.dias_minimos_venta;

  if p_bloquear then
    perform 1 from lote l where l.id_producto = p_id_producto and l.estado = 'VIGENTE' for update;
  end if;

  for r in select l.id_lote, l.codigo_lote, l.fecha_caducidad, l.cantidad_disponible
             from lote l
            where l.id_producto = p_id_producto and l.estado = 'VIGENTE'
              and l.cantidad_disponible > 0 and l.fecha_caducidad >= v_min
            order by l.fecha_caducidad, l.id_lote loop
    v_vendibles := v_vendibles + r.cantidad_disponible;
    if v_rest > 0 then
      v_tomar := least(v_rest, r.cantidad_disponible);
      id_lote := r.id_lote; codigo_lote := r.codigo_lote; fecha_caducidad := r.fecha_caducidad; tomar := v_tomar;
      return next;
      v_rest := v_rest - v_tomar;
    end if;
  end loop;

  if v_rest > 0 then
    raise exception 'Existencia insuficiente de "%": se pidieron %, hay % vendibles (con al menos % días de vida).',
      v_prod.nombre, p_cantidad, v_vendibles, v_prod.dias_minimos_venta using errcode = 'P0001';
  end if;
end $$;

create or replace function simular_fefo(p_lineas jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_res jsonb := '[]'::jsonb; ln record; v_asig jsonb; v_prod record;
begin
  perform fn_exigir('ventas.registrar');
  for ln in select (e->>'id_producto')::int as id_producto, sum((e->>'cantidad')::int)::int as cantidad
              from jsonb_array_elements(coalesce(p_lineas, '[]'::jsonb)) e group by 1 loop
    select nombre, precio_venta into v_prod from producto where id_producto = ln.id_producto;
    begin
      select coalesce(jsonb_agg(to_jsonb(a)), '[]'::jsonb) into v_asig
        from fn_fefo_asignar(ln.id_producto, ln.cantidad, false) a;
      v_res := v_res || jsonb_build_object('id_producto', ln.id_producto, 'producto', v_prod.nombre,
                 'cantidad', ln.cantidad, 'precio', v_prod.precio_venta, 'ok', true, 'asignaciones', v_asig);
    exception when others then
      v_res := v_res || jsonb_build_object('id_producto', ln.id_producto, 'producto', v_prod.nombre,
                 'cantidad', ln.cantidad, 'precio', v_prod.precio_venta, 'ok', false, 'error', sqlerrm);
    end;
  end loop;
  return v_res;
end $$;

create or replace function venta_registrar(p_id_cliente int, p_lineas jsonb, p_usuario text default null)
returns bigint language plpgsql security definer set search_path = public as $$
declare v_id bigint; ln record; a record; v_precio numeric;
begin
  perform fn_set_usuario(p_usuario); perform fn_exigir('ventas.registrar');
  if not exists (select 1 from cliente where id_cliente = p_id_cliente and activo) then
    raise exception 'Seleccione un cliente activo.' using errcode = 'P0001';
  end if;
  if p_lineas is null or jsonb_array_length(p_lineas) = 0 then
    raise exception 'El carrito está vacío.' using errcode = 'P0001';
  end if;

  insert into venta (id_cliente) values (p_id_cliente) returning id_venta into v_id;

  for ln in select (e->>'id_producto')::int as id_producto, sum((e->>'cantidad')::int)::int as cantidad
              from jsonb_array_elements(p_lineas) e group by 1 order by 1 loop   -- orden fijo: evita interbloqueos
    select precio_venta into v_precio from producto where id_producto = ln.id_producto;
    for a in select * from fn_fefo_asignar(ln.id_producto, ln.cantidad, true) loop
      insert into movimiento (id_lote, id_venta, tipo, cantidad, precio_unitario)
      values (a.id_lote, v_id, 'VENTA', a.tomar, v_precio);
    end loop;
  end loop;
  return v_id;
end $$;

create or replace function venta_cancelar(p_id_venta bigint, p_motivo text, p_usuario text default null)
returns void language plpgsql security definer set search_path = public as $$
declare m record;
begin
  perform fn_set_usuario(p_usuario); perform fn_exigir('ventas.cancelar');
  perform 1 from venta where id_venta = p_id_venta for update;
  if not found then raise exception 'La venta no existe.' using errcode = 'P0001'; end if;
  update venta set estado = 'CANCELADA', motivo_cancelacion = p_motivo where id_venta = p_id_venta;
  for m in select id_lote, cantidad, precio_unitario from movimiento
            where id_venta = p_id_venta and tipo = 'VENTA' order by id_lote loop
    insert into movimiento (id_lote, id_venta, tipo, cantidad, precio_unitario, motivo)
    values (m.id_lote, p_id_venta, 'DEVOLUCION', m.cantidad, m.precio_unitario, 'Cancelación: ' || trim(p_motivo));
  end loop;
end $$;

create or replace function marcar_caducados() returns int
language plpgsql security definer set search_path = public as $$
declare v_n int;
begin
  perform fn_exigir(null);
  perform fn_set_usuario('sistema');
  perform set_config('lotesmart.interno', '1', true);
  update lote set estado = 'CADUCADO'
   where estado in ('VIGENTE','AGOTADO') and fecha_caducidad < fn_hoy();
  get diagnostics v_n = row_count;
  perform set_config('lotesmart.interno', '0', true);
  return v_n;
end $$;

create or replace function rpt_ventas(p_desde date, p_hasta date, p_incluir_canceladas boolean default false)
returns table (folio text, fecha timestamptz, cliente text, estado text, unidades bigint,
               total numeric, costo numeric, margen numeric, usuario text)
language sql stable as $$
  select fn_exigir('reportes.ver');
  select v.folio, v.fecha, v.cliente, v.estado::text, v.unidades, v.total,
         (v.total - v.margen_bruto)::numeric(12,2), v.margen_bruto, v.usuario
    from v_venta_resumen v
   where (v.fecha at time zone 'America/Mexico_City')::date between p_desde and p_hasta
     and (p_incluir_canceladas or v.estado = 'REGISTRADA')
   order by v.fecha;
$$;

create or replace function rpt_ventas_dia(p_desde date, p_hasta date)
returns table (dia date, ventas bigint, importe numeric, margen numeric)
language sql stable as $$
  select fn_exigir('reportes.ver');
  select d::date, count(v.id_venta), coalesce(sum(v.total), 0)::numeric(12,2), coalesce(sum(v.margen_bruto), 0)::numeric(12,2)
    from generate_series(p_desde, p_hasta, interval '1 day') d
    left join v_venta_resumen v
      on (v.fecha at time zone 'America/Mexico_City')::date = d::date and v.estado = 'REGISTRADA'
   group by d order by d;
$$;

create or replace function rpt_ventas_producto(p_desde date, p_hasta date)
returns table (sku text, producto text, unidad text, ventas bigint, unidades bigint,
               importe numeric, costo numeric, margen numeric, margen_pct numeric)
language sql stable as $$
  select fn_exigir('reportes.ver');
  select p.sku, p.nombre, u.clave, count(distinct v.id_venta), sum(m.cantidad),
         sum(m.cantidad * m.precio_unitario)::numeric(12,2),
         sum(m.cantidad * l.costo_unitario)::numeric(12,2),
         sum(m.cantidad * (m.precio_unitario - l.costo_unitario))::numeric(12,2),
         round(100 * sum(m.cantidad * (m.precio_unitario - l.costo_unitario)) / nullif(sum(m.cantidad * m.precio_unitario), 0), 1)
    from movimiento m
    join venta v on v.id_venta = m.id_venta and v.estado = 'REGISTRADA'
    join lote l on l.id_lote = m.id_lote
    join producto p on p.id_producto = l.id_producto
    join unidad_medida u on u.id_unidad = p.id_unidad
   where m.tipo = 'VENTA' and (v.fecha at time zone 'America/Mexico_City')::date between p_desde and p_hasta
   group by p.id_producto, u.clave
   order by 6 desc;
$$;

create or replace function rpt_ventas_cliente(p_desde date, p_hasta date)
returns table (cliente text, rfc text, ventas bigint, unidades numeric, importe numeric, margen numeric, ultima_compra timestamptz)
language sql stable as $$
  select fn_exigir('reportes.ver');
  select c.nombre, c.rfc, count(v.id_venta), sum(v.unidades)::numeric, sum(v.total)::numeric(12,2),
         sum(v.margen_bruto)::numeric(12,2), max(v.fecha)
    from v_venta_resumen v
    join cliente c on c.id_cliente = v.id_cliente
   where v.estado = 'REGISTRADA' and (v.fecha at time zone 'America/Mexico_City')::date between p_desde and p_hasta
   group by c.id_cliente
   order by 5 desc;
$$;

create or replace function rpt_inventario()
returns table (sku text, producto text, unidad text, activo boolean, lotes bigint, stock_vigente bigint, stock_vendible bigint,
               stock_no_vendible bigint, valor_vigente numeric, valor_en_riesgo numeric, valor_no_vendible numeric,
               stock_minimo int, alerta_reorden boolean)
language sql stable as $$
  select fn_exigir('reportes.ver');
  select p.sku, p.nombre, p.unidad, p.activo,
         count(l.id_lote) filter (where l.cantidad_disponible > 0),
         p.stock_vigente, p.stock_vendible,
         coalesce(sum(l.cantidad_disponible) filter (where l.estado in ('CADUCADO','BLOQUEADO')), 0),
         coalesce(sum(l.valor_existencia) filter (where l.estado = 'VIGENTE'), 0),
         coalesce(sum(l.valor_existencia) filter (where l.semaforo = 'ROJO'), 0),
         coalesce(sum(l.valor_existencia) filter (where l.estado in ('CADUCADO','BLOQUEADO')), 0),
         p.stock_minimo, p.alerta_reorden
    from v_producto p
    left join v_lote_detalle l on l.id_producto = p.id_producto
   group by p.id_producto, p.sku, p.nombre, p.unidad, p.activo, p.stock_vigente, p.stock_vendible, p.stock_minimo, p.alerta_reorden
   order by 9 desc;
$$;

create or replace function rpt_por_caducar(p_dias int)
returns table (codigo_lote text, producto text, proveedor text, fecha_caducidad date, dias_restantes int,
               existencia int, unidad text, costo_unitario numeric, valor numeric, estado text)
language sql stable as $$
  select fn_exigir('reportes.ver');
  select l.codigo_lote, l.producto, l.proveedor, l.fecha_caducidad, l.dias_restantes, l.cantidad_disponible,
         l.unidad, l.costo_unitario, l.valor_existencia, l.semaforo
    from v_lote_detalle l
   where l.cantidad_disponible > 0 and l.dias_restantes <= p_dias
   order by l.fecha_caducidad, l.id_lote;
$$;

create or replace function rpt_mermas_ajustes(p_desde date, p_hasta date)
returns table (fecha timestamptz, tipo text, codigo_lote text, producto text, cantidad int, valor_costo numeric, motivo text, usuario text)
language sql stable as $$
  select fn_exigir('reportes.ver');
  select m.fecha, m.tipo::text, l.codigo_lote, p.nombre,
         case when m.tipo = 'AJUSTE_POSITIVO' then m.cantidad else -m.cantidad end,
         (case when m.tipo = 'AJUSTE_POSITIVO' then 1 else -1 end * m.cantidad * l.costo_unitario)::numeric(12,2),
         m.motivo, m.usuario
    from movimiento m
    join lote l on l.id_lote = m.id_lote
    join producto p on p.id_producto = l.id_producto
   where m.tipo in ('MERMA','AJUSTE_NEGATIVO','AJUSTE_POSITIVO')
     and (m.fecha at time zone 'America/Mexico_City')::date between p_desde and p_hasta
   order by m.fecha;
$$;

create or replace function rpt_entradas_proveedor(p_desde date, p_hasta date)
returns table (proveedor text, rfc text, lotes bigint, unidades bigint, costo_total numeric, productos text)
language sql stable as $$
  select fn_exigir('reportes.ver');
  select pr.nombre, pr.rfc, count(l.id_lote), sum(l.cantidad_inicial),
         sum(l.cantidad_inicial * l.costo_unitario)::numeric(12,2),
         string_agg(distinct p.nombre, ', ')
    from lote l
    join proveedor pr on pr.id_proveedor = l.id_proveedor
    join producto p on p.id_producto = l.id_producto
   where (l.fecha_entrada at time zone 'America/Mexico_City')::date between p_desde and p_hasta
   group by pr.id_proveedor
   order by 5 desc;
$$;

create or replace function rpt_kardex(p_desde date, p_hasta date, p_id_producto int default null)
returns table (fecha timestamptz, producto text, codigo_lote text, concepto text, referencia text,
               entrada int, salida int, saldo bigint, usuario text)
language sql stable as $$
  select fn_exigir('reportes.ver');
  with mov as (
    select l.fecha_entrada as fecha, l.id_producto, l.codigo_lote, 'ENTRADA'::text as concepto,
           pr.nombre::text as referencia, l.cantidad_inicial as entrada, 0 as salida, null::text as usuario, l.id_lote::bigint - 1000000000000 as orden
      from lote l join proveedor pr on pr.id_proveedor = l.id_proveedor
    union all
    select m.fecha, l.id_producto, l.codigo_lote, m.tipo::text,
           coalesce(fn_folio(m.id_venta) || ' · ' || c.nombre, m.motivo),
           case when m.tipo in ('AJUSTE_POSITIVO','DEVOLUCION') then m.cantidad else 0 end,
           case when m.tipo in ('VENTA','MERMA','AJUSTE_NEGATIVO') then m.cantidad else 0 end,
           m.usuario, m.id_movimiento
      from movimiento m
      join lote l on l.id_lote = m.id_lote
      left join venta v on v.id_venta = m.id_venta
      left join cliente c on c.id_cliente = v.id_cliente
  ), con_saldo as (
    select mov.*, sum(entrada - salida) over (partition by id_producto order by fecha, orden rows between unbounded preceding and current row) as saldo
      from mov where p_id_producto is null or id_producto = p_id_producto
  )
  select s.fecha, p.nombre, s.codigo_lote, s.concepto, s.referencia, s.entrada, s.salida, s.saldo, s.usuario
    from con_saldo s join producto p on p.id_producto = s.id_producto
   where (s.fecha at time zone 'America/Mexico_City')::date between p_desde and p_hasta
   order by p.nombre, s.fecha, s.orden;
$$;

create or replace function mi_perfil() returns jsonb language plpgsql security definer set search_path = public as $$
declare c jsonb := nullif(current_setting('request.jwt.claims', true), '')::jsonb; v usuario%rowtype; r rol%rowtype;
begin
  if fn_uid() is null then raise exception 'Inicia sesión para continuar.' using errcode = 'P0001'; end if;
  select * into v from usuario where auth_id = fn_uid();
  if not found then
    insert into usuario (auth_id, email, nombre, id_rol)
    values (fn_uid(), coalesce(c ->> 'email', 'sin-correo'),
            coalesce(nullif(trim(c -> 'user_metadata' ->> 'nombre'), ''), split_part(coalesce(c ->> 'email', 'usuario'), '@', 1)),
            (select id_rol from rol where clave = case when exists (
               select 1 from usuario u join rol_permiso rp on rp.id_rol = u.id_rol where u.activo and rp.permiso = 'usuarios.administrar')
             then 'CONSULTA' else 'ADMIN' end))
    on conflict (auth_id) do nothing;
    select * into v from usuario where auth_id = fn_uid();
  end if;
  select * into r from rol where id_rol = v.id_rol;
  return jsonb_build_object('id_usuario', v.id_usuario, 'nombre', v.nombre, 'email', v.email, 'activo', v.activo,
    'rol', r.clave, 'rol_nombre', r.nombre,
    'permisos', (select coalesce(jsonb_agg(permiso order by permiso), '[]'::jsonb) from rol_permiso where id_rol = v.id_rol));
end $$;

create or replace function mi_nombre(p_nombre text) returns void language plpgsql security definer set search_path = public as $$
begin
  perform fn_exigir(null);
  update usuario set nombre = trim(p_nombre) where auth_id = fn_uid();
end $$;

create or replace function usuario_actualizar(p_id_usuario int, p_nombre text, p_id_rol int, p_activo boolean, p_usuario text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform fn_set_usuario(p_usuario); perform fn_exigir('usuarios.administrar');
  update usuario set nombre = trim(p_nombre), id_rol = p_id_rol, activo = p_activo where id_usuario = p_id_usuario;
  if not found then raise exception 'El usuario no existe.' using errcode = 'P0001'; end if;
  if not exists (select 1 from usuario u join rol_permiso rp on rp.id_rol = u.id_rol
                  where u.activo and rp.permiso = 'usuarios.administrar') then
    raise exception 'Debe quedar al menos un administrador activo.' using errcode = 'P0001';
  end if;
end $$;

create or replace function rol_permiso_cambiar(p_id_rol int, p_permiso text, p_conceder boolean, p_usuario text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_rol text;
begin
  perform fn_set_usuario(p_usuario); perform fn_exigir('usuarios.administrar');
  select clave into v_rol from rol where id_rol = p_id_rol;
  if v_rol is null then raise exception 'El rol no existe.' using errcode = 'P0001'; end if;
  if v_rol = 'ADMIN' and p_permiso = 'usuarios.administrar' and not p_conceder then
    raise exception 'El rol Administrador siempre conserva la administración de usuarios.' using errcode = 'P0001';
  end if;
  if p_conceder then
    insert into rol_permiso (id_rol, permiso) values (p_id_rol, p_permiso) on conflict do nothing;
  else
    delete from rol_permiso where id_rol = p_id_rol and permiso = p_permiso;
  end if;
  insert into auditoria (tabla, id_registro, accion, detalle)
  values ('rol_permiso', p_id_rol, 'MODIFICACION', 'rol: ' || v_rol || '; permiso: ' || p_permiso || '; ' || case when p_conceder then 'concedido' else 'retirado' end);
end $$;

create or replace function fn_perfil_desde_auth() returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.usuario (auth_id, email, nombre, id_rol)
  values (new.id, coalesce(new.email, 'sin-correo'),
          coalesce(nullif(trim(new.raw_user_meta_data ->> 'nombre'), ''), split_part(coalesce(new.email, 'usuario'), '@', 1)),
          (select id_rol from public.rol where clave = case when exists (
             select 1 from public.usuario u join public.rol_permiso rp on rp.id_rol = u.id_rol where u.activo and rp.permiso = 'usuarios.administrar')
           then 'CONSULTA' else 'ADMIN' end))
  on conflict (auth_id) do nothing;
  return new;
end $$;

drop trigger if exists trg_aud_usuario on usuario;
create trigger trg_aud_usuario after insert or update or delete on usuario for each row execute function trg_auditar('id_usuario');

alter table unidad_medida enable row level security;
alter table proveedor     enable row level security;
alter table cliente       enable row level security;
alter table producto      enable row level security;
alter table lote          enable row level security;
alter table venta         enable row level security;
alter table movimiento    enable row level security;
alter table auditoria     enable row level security;
alter table rol           enable row level security;
alter table permiso       enable row level security;
alter table rol_permiso   enable row level security;
alter table usuario       enable row level security;

drop policy if exists lectura on unidad_medida;
drop policy if exists lectura on proveedor;
drop policy if exists lectura on cliente;
drop policy if exists lectura on producto;
drop policy if exists lectura on lote;
drop policy if exists lectura on venta;
drop policy if exists lectura on movimiento;
drop policy if exists lectura on auditoria;
drop policy if exists lectura on rol;
drop policy if exists lectura on permiso;
drop policy if exists lectura on rol_permiso;
drop policy if exists lectura on usuario;

-- Leer: cualquier usuario con perfil ACTIVO. Un usuario desactivado no ve nada.
create policy lectura on unidad_medida for select to authenticated using (fn_activo());
create policy lectura on proveedor     for select to authenticated using (fn_activo());
create policy lectura on cliente       for select to authenticated using (fn_activo());
create policy lectura on producto      for select to authenticated using (fn_activo());
create policy lectura on lote          for select to authenticated using (fn_activo());
create policy lectura on venta         for select to authenticated using (fn_activo());
create policy lectura on movimiento    for select to authenticated using (fn_activo());
create policy lectura on rol           for select to authenticated using (fn_activo());
create policy lectura on permiso       for select to authenticated using (fn_activo());
create policy lectura on rol_permiso   for select to authenticated using (fn_activo());
-- La auditoría solo la ve quien tiene ese permiso.
create policy lectura on auditoria     for select to authenticated using (fn_tiene_permiso('auditoria.ver'));
-- Cada quien ve su perfil; el administrador ve a todos.
create policy lectura on usuario       for select to authenticated using (auth_id = fn_uid() or fn_tiene_permiso('usuarios.administrar'));

grant usage on schema public to anon, authenticated;
revoke all on unidad_medida, proveedor, cliente, producto, lote, venta, movimiento, auditoria, rol, permiso, rol_permiso, usuario from anon, authenticated;
revoke all on v_lote_detalle, v_producto, v_proveedor, v_cliente, v_venta_resumen,
              v_movimiento_detalle, v_trazabilidad, v_tablero, v_auditoria from anon, authenticated;
grant select on unidad_medida, proveedor, cliente, producto, lote, venta, movimiento, auditoria, rol, permiso, rol_permiso, usuario to authenticated;
grant select on v_lote_detalle, v_producto, v_proveedor, v_cliente, v_venta_resumen,
                v_movimiento_detalle, v_trazabilidad, v_tablero, v_auditoria to authenticated;

-- Funciones internas: no se exponen como RPC.
revoke execute on function fn_fefo_asignar(int, int, boolean), fn_set_usuario(text), fn_interno()
  from public, anon, authenticated;

-- Funciones de la app: solo con sesión iniciada.
do $$
declare f text;
begin
  foreach f in array array[
    'fn_hoy()', 'fn_usuario()', 'fn_estado_lote(estado_lote, int, date)', 'fn_folio(bigint)',
    'unidad_guardar(text, text, text)',
    'producto_guardar(int, text, text, int, numeric, int, int, text)',
    'producto_baja(int, text)', 'producto_reactivar(int, text)', 'producto_eliminar(int, text)', 'producto_imagen(int, text, text)',
    'proveedor_guardar(int, text, text, text, text)',
    'proveedor_baja(int, text)', 'proveedor_reactivar(int, text)', 'proveedor_eliminar(int, text)',
    'cliente_guardar(int, text, text, text, text, text)',
    'cliente_baja(int, text)', 'cliente_reactivar(int, text)', 'cliente_eliminar(int, text)',
    'lote_alta(int, int, text, date, int, numeric, text)',
    'lote_modificar(int, int, int, text, date, int, numeric, text)',
    'lote_bloquear(int, text, text)', 'lote_desbloquear(int, text)', 'lote_eliminar(int, text)',
    'registrar_merma(int, int, text, text)', 'registrar_ajuste(int, boolean, int, text, text)',
    'simular_fefo(jsonb)', 'venta_registrar(int, jsonb, text)', 'venta_cancelar(bigint, text, text)',
    'marcar_caducados()',
    'rpt_ventas(date, date, boolean)', 'rpt_ventas_dia(date, date)', 'rpt_ventas_producto(date, date)',
    'rpt_ventas_cliente(date, date)', 'rpt_inventario()', 'rpt_por_caducar(int)',
    'rpt_mermas_ajustes(date, date)', 'rpt_entradas_proveedor(date, date)', 'rpt_kardex(date, date, int)',
    'fn_uid()', 'fn_activo()', 'fn_tiene_permiso(text)', 'fn_exigir(text)',
    'mi_perfil()', 'mi_nombre(text)', 'usuario_actualizar(int, text, int, boolean, text)', 'rol_permiso_cambiar(int, text, boolean, text)'
  ] loop
    execute format('revoke execute on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;


-- =====================================================================
-- Perfiles automáticos: cada cuenta nueva de Supabase Auth recibe su perfil
-- (rol Consulta; la primera cuenta de la instalación queda como Administrador).
-- Las cuentas que ya existían se registran aquí mismo.
-- =====================================================================
create or replace function fn_perfil_desde_auth() returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.usuario (auth_id, email, nombre, id_rol)
  values (new.id, coalesce(new.email, 'sin-correo'),
          coalesce(nullif(trim(new.raw_user_meta_data ->> 'nombre'), ''), split_part(coalesce(new.email, 'usuario'), '@', 1)),
          (select id_rol from public.rol where clave = case when exists (
             select 1 from public.usuario u join public.rol_permiso rp on rp.id_rol = u.id_rol where u.activo and rp.permiso = 'usuarios.administrar')
           then 'CONSULTA' else 'ADMIN' end))
  on conflict (auth_id) do nothing;
  return new;
end $$;
revoke execute on function fn_perfil_desde_auth() from public, anon, authenticated;

do $$
declare a record;
begin
  if to_regclass('auth.users') is null then
    raise notice 'Supabase Auth no disponible: los perfiles se crearán al iniciar sesión.';
    return;
  end if;
  execute 'drop trigger if exists lotesmart_perfil_nuevo on auth.users';
  execute 'create trigger lotesmart_perfil_nuevo after insert on auth.users for each row execute function public.fn_perfil_desde_auth()';
  for a in execute 'select id, email, raw_user_meta_data from auth.users order by created_at' loop
    insert into usuario (auth_id, email, nombre, id_rol)
    values (a.id, coalesce(a.email, 'sin-correo'),
            coalesce(nullif(trim(a.raw_user_meta_data ->> 'nombre'), ''), split_part(coalesce(a.email, 'usuario'), '@', 1)),
            (select id_rol from rol where clave = case when exists (
               select 1 from usuario u join rol_permiso rp on rp.id_rol = u.id_rol where u.activo and rp.permiso = 'usuarios.administrar')
             then 'CONSULTA' else 'ADMIN' end))
    on conflict (auth_id) do nothing;
  end loop;
end $$;


notify pgrst, 'reload schema';
