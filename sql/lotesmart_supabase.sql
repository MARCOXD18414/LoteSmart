-- =====================================================================
--  LoteSmart · Inventario por lotes con caducidad y despacho FEFO
--  Script completo para Supabase (PostgreSQL 15+)
--
--  Cómo usarlo: Supabase → SQL Editor → New query → pega todo → Run.
--  Se puede volver a ejecutar: borra y recrea SOLO los objetos de LoteSmart.
--
--  Contenido
--   0. Limpieza (re-ejecución segura)
--   1. Tipos y utilidades
--   2. Tablas (3FN) con restricciones
--   3. Triggers de reglas de negocio
--   4. Auditoría automática
--   5. Vistas (cálculos derivados)
--   6. Funciones RPC (altas, bajas, modificaciones, ventas FEFO...)
--   7. Reporteador (funciones de reportes)
--   7b. Usuarios, roles y permisos
--   8. Seguridad e inicio de sesión (Supabase Auth + RLS)
--   9. Datos de prueba (los del guion de demostración)
-- =====================================================================

-- =====================================================================
-- 0. LIMPIEZA
-- =====================================================================
drop view  if exists v_tablero, v_trazabilidad, v_movimiento_detalle, v_venta_resumen,
                     v_lote_detalle, v_producto, v_proveedor, v_cliente, v_auditoria cascade;
drop table if exists auditoria, movimiento, venta, lote, producto, cliente, proveedor, unidad_medida,
                     usuario, rol_permiso, permiso, rol cascade;
drop type  if exists estado_lote, estado_venta, tipo_movimiento cascade;
drop function if exists
  fn_hoy, fn_usuario, fn_set_usuario, fn_interno, fn_estado_lote, fn_folio,
  trg_lote_bi, trg_lote_bu, trg_lote_bd, trg_mov_bi, trg_mov_ai, trg_mov_inmutable,
  trg_venta_bu, trg_venta_bd, trg_catalogo_bi, trg_producto_bd, trg_proveedor_bd, trg_cliente_bd,
  trg_auditar, fn_fefo_asignar,
  producto_guardar, producto_baja, producto_reactivar, producto_eliminar, producto_imagen,
  proveedor_guardar, proveedor_baja, proveedor_reactivar, proveedor_eliminar,
  cliente_guardar, cliente_baja, cliente_reactivar, cliente_eliminar,
  unidad_guardar,
  lote_alta, lote_modificar, lote_bloquear, lote_desbloquear, lote_eliminar,
  registrar_merma, registrar_ajuste,
  simular_fefo, venta_registrar, venta_cancelar, marcar_caducados,
  rpt_ventas, rpt_ventas_dia, rpt_ventas_producto, rpt_ventas_cliente, rpt_inventario,
  rpt_por_caducar, rpt_mermas_ajustes, rpt_entradas_proveedor, rpt_kardex,
  fn_uid, fn_activo, fn_tiene_permiso, fn_exigir, mi_perfil, mi_nombre, usuario_actualizar, rol_permiso_cambiar,
  fn_perfil_desde_auth, usuario_crear, usuario_eliminar cascade;

-- =====================================================================
-- 1. TIPOS Y UTILIDADES
-- =====================================================================
create type estado_lote     as enum ('VIGENTE','AGOTADO','CADUCADO','BLOQUEADO');
create type estado_venta    as enum ('REGISTRADA','CANCELADA');
create type tipo_movimiento as enum ('VENTA','MERMA','AJUSTE_NEGATIVO','AJUSTE_POSITIVO','DEVOLUCION');

-- "Hoy" en la zona horaria de la operación (Supabase corre en UTC).
create function fn_hoy() returns date language sql stable as
$$ select (now() at time zone 'America/Mexico_City')::date $$;

-- Usuario de Supabase Auth que hace la petición (null desde el SQL Editor).
create function fn_uid() returns uuid language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claim.sub', true), ''),
                  nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')::uuid
$$;

-- Nombre que firma movimientos y auditoría (equivale a @usuario_app).
-- Se toma del perfil del usuario con sesión (tabla usuario); así nadie
-- puede firmar con el nombre de otro.
create function fn_usuario() returns text language plpgsql stable security definer set search_path = public as $$
declare v text; c jsonb := nullif(current_setting('request.jwt.claims', true), '')::jsonb;
begin
  if fn_uid() is not null and to_regclass('public.usuario') is not null then
    execute 'select nombre from usuario where auth_id = $1' into v using fn_uid();
  end if;
  return left(coalesce(v, nullif(c -> 'user_metadata' ->> 'nombre', ''), nullif(c ->> 'email', ''),
                       nullif(current_setting('app.usuario', true), ''), session_user::text), 120);
end $$;

create function fn_set_usuario(p_usuario text) returns void language sql as
$$ select set_config('app.usuario', coalesce(nullif(trim(p_usuario), ''), 'web'), true) $$;

-- Bandera interna: solo los procesos del sistema pueden tocar existencia y estado.
create function fn_interno() returns boolean language sql stable as
$$ select coalesce(current_setting('lotesmart.interno', true), '') = '1' $$;

-- Estado que le corresponde a un lote según sus datos.
create function fn_estado_lote(p_actual estado_lote, p_disp int, p_cad date)
returns estado_lote language sql stable as $$
  select case
    when p_actual = 'BLOQUEADO'  then 'BLOQUEADO'::estado_lote
    when p_cad < fn_hoy()        then 'CADUCADO'::estado_lote
    when p_disp = 0              then 'AGOTADO'::estado_lote
    else 'VIGENTE'::estado_lote end
$$;

create function fn_folio(p_id bigint) returns text language sql immutable as
$$ select 'V-' || lpad(p_id::text, 6, '0') $$;

-- =====================================================================
-- 2. TABLAS (Tercera Forma Normal)
--  · Cada catálogo vive en su tabla: unidad_medida, proveedor, cliente, producto.
--  · venta guarda solo la llave del cliente; el total se CALCULA (v_venta_resumen).
--  · lote.cantidad_disponible es la única redundancia controlada: la mantiene
--    un trigger a partir de los movimientos y nadie puede escribirla a mano.
-- =====================================================================
create table unidad_medida (
  id_unidad  smallint generated always as identity primary key,
  clave      varchar(20)  not null,
  nombre     varchar(60)  not null,
  constraint uq_unidad_clave unique (clave),
  constraint ck_unidad_clave check (clave = upper(trim(clave)) and char_length(clave) >= 2)
);

create table proveedor (
  id_proveedor  int generated always as identity primary key,
  rfc           varchar(13)  not null,
  nombre        varchar(120) not null,
  telefono      varchar(20),
  activo        boolean not null default true,
  creado_en     timestamptz not null default now(),
  constraint uq_proveedor_rfc unique (rfc),
  constraint ck_proveedor_rfc check (char_length(rfc) between 12 and 13
                                     and rfc ~ '^[A-ZÑ&]{3,4}[0-9]{6}[A-Z0-9]{3}$'),
  constraint ck_proveedor_nombre check (char_length(trim(nombre)) >= 3)
);

create table cliente (
  id_cliente  int generated always as identity primary key,
  nombre      varchar(120) not null,
  rfc         varchar(13),
  telefono    varchar(20),
  correo      varchar(120),
  activo      boolean not null default true,
  creado_en   timestamptz not null default now(),
  constraint uq_cliente_nombre unique (nombre),
  constraint uq_cliente_rfc unique (rfc),
  constraint ck_cliente_rfc check (rfc is null or rfc ~ '^[A-ZÑ&]{3,4}[0-9]{6}[A-Z0-9]{3}$'),
  constraint ck_cliente_nombre check (char_length(trim(nombre)) >= 3),
  constraint ck_cliente_correo check (correo is null or correo ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$')
);

create table producto (
  id_producto        int generated always as identity primary key,
  sku                varchar(20)   not null,
  nombre             varchar(120)  not null,
  id_unidad          smallint      not null references unidad_medida(id_unidad) on delete restrict,
  precio_venta       numeric(10,2) not null,
  stock_minimo       int           not null default 0,
  dias_minimos_venta int           not null default 0,
  imagen_path        varchar(200),            -- ruta de la foto en Supabase Storage (bucket "productos")
  activo             boolean       not null default true,
  creado_en          timestamptz   not null default now(),
  constraint uq_producto_sku unique (sku),
  constraint ck_producto_sku check (char_length(trim(sku)) >= 2),
  constraint ck_producto_nombre check (char_length(trim(nombre)) >= 3),
  constraint ck_producto_precio check (precio_venta > 0),
  constraint ck_producto_stock check (stock_minimo >= 0),
  constraint ck_producto_dias check (dias_minimos_venta >= 0)
);

create table lote (
  id_lote             int generated always as identity primary key,
  id_producto         int  not null references producto(id_producto)   on delete restrict,
  id_proveedor        int  not null references proveedor(id_proveedor) on delete restrict,
  codigo_lote         varchar(30)   not null,
  fecha_caducidad     date          not null,
  cantidad_inicial    int           not null,
  cantidad_disponible int           not null,
  costo_unitario      numeric(10,2) not null,
  estado              estado_lote   not null default 'VIGENTE',
  motivo_bloqueo      varchar(200),
  fecha_entrada       timestamptz   not null default now(),
  constraint uq_lote_codigo unique (id_producto, codigo_lote),
  constraint ck_lote_inicial check (cantidad_inicial > 0),
  constraint ck_lote_disponible check (cantidad_disponible between 0 and cantidad_inicial),
  constraint ck_lote_costo check (costo_unitario > 0),
  constraint ck_lote_bloqueo check ((estado = 'BLOQUEADO') = (motivo_bloqueo is not null))
);
-- Índice FEFO: lotes de un producto por caducidad y antigüedad.
create index ix_lote_fefo on lote (id_producto, estado, fecha_caducidad, id_lote);
create index ix_lote_proveedor on lote (id_proveedor);

create table venta (
  id_venta            bigint generated always as identity primary key,
  id_cliente          int  not null references cliente(id_cliente) on delete restrict,
  fecha               timestamptz  not null default now(),
  estado              estado_venta not null default 'REGISTRADA',
  motivo_cancelacion  varchar(200),
  fecha_cancelacion   timestamptz,
  usuario             varchar(120) not null default fn_usuario(),
  constraint ck_venta_cancelacion check (
    (estado = 'REGISTRADA' and motivo_cancelacion is null and fecha_cancelacion is null) or
    (estado = 'CANCELADA'  and motivo_cancelacion is not null and fecha_cancelacion is not null))
);
create index ix_venta_cliente on venta (id_cliente);
create index ix_venta_fecha on venta (fecha);

create table movimiento (
  id_movimiento   bigint generated always as identity primary key,
  id_lote         int    not null references lote(id_lote)   on delete restrict,
  id_venta        bigint          references venta(id_venta) on delete restrict,
  tipo            tipo_movimiento not null,
  cantidad        int             not null,
  precio_unitario numeric(10,2),
  motivo          varchar(200),
  usuario         varchar(120)    not null default fn_usuario(),
  fecha           timestamptz     not null default now(),
  constraint ck_mov_cantidad check (cantidad > 0),
  constraint ck_mov_venta check (
    (tipo in ('VENTA','DEVOLUCION') and id_venta is not null) or
    (tipo not in ('VENTA','DEVOLUCION') and id_venta is null)),
  constraint ck_mov_precio check (tipo <> 'VENTA' or precio_unitario is not null)
);
create index ix_mov_lote on movimiento (id_lote);
create index ix_mov_venta on movimiento (id_venta);

create table auditoria (
  id_auditoria bigint generated always as identity primary key,
  tabla        varchar(30)  not null,
  id_registro  bigint       not null,
  accion       varchar(20)  not null,
  detalle      varchar(500),
  usuario      varchar(120) not null default fn_usuario(),
  fecha        timestamptz  not null default now(),
  constraint ck_aud_accion check (accion in ('ALTA','MODIFICACION','BAJA','REACTIVACION',
                                             'CAMBIO_ESTADO','CANCELACION','ELIMINACION'))
);
create index ix_aud_tabla on auditoria (tabla, id_registro);

-- ---------- Roles y permisos (control de acceso por rol) ----------
create table rol (
  id_rol      smallint generated always as identity primary key,
  clave       varchar(20)  not null,
  nombre      varchar(40)  not null,
  descripcion varchar(200),
  constraint uq_rol_clave unique (clave),
  constraint ck_rol_clave check (clave = upper(clave))
);

create table permiso (
  clave       varchar(40)  primary key,
  descripcion varchar(120) not null,
  orden       smallint     not null default 0
);

create table rol_permiso (
  id_rol   smallint    not null references rol(id_rol) on delete cascade,
  permiso  varchar(40) not null references permiso(clave) on delete cascade,
  primary key (id_rol, permiso)
);

-- Perfil de cada persona dentro de LoteSmart. Lo crea un administrador;
-- auth_id queda vacío hasta que la persona tiene su cuenta de Supabase Auth.
create table usuario (
  id_usuario int generated always as identity primary key,
  auth_id    uuid,                     -- null = dado de alta, cuenta pendiente
  email      varchar(160) not null,
  nombre     varchar(80)  not null,
  id_rol     smallint     not null references rol(id_rol) on delete restrict,
  activo     boolean      not null default true,
  creado_en  timestamptz  not null default now(),
  constraint uq_usuario_auth unique (auth_id),
  constraint ck_usuario_nombre check (char_length(trim(nombre)) >= 2)
);
create index ix_usuario_rol on usuario (id_rol);
create unique index uq_usuario_email on usuario (lower(email));

insert into rol (clave, nombre, descripcion) values
  ('ADMIN',    'Administrador', 'Todo, incluida la administración de usuarios y permisos.'),
  ('ALMACEN',  'Almacén',       'Productos, proveedores, entradas de lotes, mermas y ajustes.'),
  ('VENDEDOR', 'Vendedor',      'Registra ventas con FEFO y da de alta clientes.'),
  ('CONSULTA', 'Consulta',      'Solo puede ver la información y los reportes.');

insert into permiso (clave, descripcion, orden) values
  ('tablero.ver',           'Ver el tablero de caducidad y valor en riesgo', 0),
  ('catalogo.editar',       'Dar de alta, modificar y dar de baja productos y proveedores', 1),
  ('clientes.editar',       'Dar de alta, modificar y dar de baja clientes', 2),
  ('lotes.editar',          'Registrar entradas de lotes, corregirlos y bloquearlos', 3),
  ('inventario.ajustar',    'Registrar mermas y ajustes de inventario', 4),
  ('ventas.registrar',      'Registrar ventas', 5),
  ('ventas.cancelar',       'Cancelar ventas', 6),
  ('registros.eliminar',    'Eliminar registros de forma definitiva', 7),
  ('reportes.ver',          'Ver y exportar reportes', 8),
  ('auditoria.ver',         'Ver la auditoría', 9),
  ('usuarios.administrar',  'Administrar usuarios, roles y permisos', 10);

insert into rol_permiso (id_rol, permiso)
select r.id_rol, p.clave from rol r cross join permiso p
 where r.clave = 'ADMIN'
    or (r.clave = 'ALMACEN'  and p.clave in ('catalogo.editar', 'lotes.editar', 'inventario.ajustar', 'reportes.ver'))
    or (r.clave = 'VENDEDOR' and p.clave in ('clientes.editar', 'ventas.registrar', 'reportes.ver'))
    or (r.clave = 'CONSULTA' and p.clave in ('reportes.ver'));

-- ¿El usuario con sesión tiene perfil activo? (sin sesión de Auth = administrador de BD)
create function fn_activo() returns boolean language plpgsql stable security definer set search_path = public as $$
begin
  if fn_uid() is null then
    return coalesce(current_setting('role', true), 'none') not in ('anon', 'authenticated');
  end if;
  return exists (select 1 from usuario where auth_id = fn_uid() and activo);
end $$;

create function fn_tiene_permiso(p_permiso text) returns boolean language plpgsql stable security definer set search_path = public as $$
begin
  if fn_uid() is null then
    return coalesce(current_setting('role', true), 'none') not in ('anon', 'authenticated');
  end if;
  return exists (select 1 from usuario u join rol_permiso rp on rp.id_rol = u.id_rol
                  where u.auth_id = fn_uid() and u.activo and rp.permiso = p_permiso);
end $$;

-- Detiene la operación si el usuario no tiene el permiso (null = basta con estar activo).
create function fn_exigir(p_permiso text) returns void language plpgsql stable security definer set search_path = public as $$
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
    raise exception 'Tu cuenta no está autorizada en LoteSmart. Pide a un administrador que te dé de alta.' using errcode = 'P0001';
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

-- =====================================================================
-- 3. TRIGGERS DE REGLAS DE NEGOCIO
-- =====================================================================

-- Normaliza textos de catálogos (mayúsculas en claves, sin espacios sobrantes).
create function trg_catalogo_bi() returns trigger language plpgsql as $$
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
create trigger trg_producto_norm  before insert or update on producto  for each row execute function trg_catalogo_bi();
create trigger trg_proveedor_norm before insert or update on proveedor for each row execute function trg_catalogo_bi();
create trigger trg_cliente_norm   before insert or update on cliente   for each row execute function trg_catalogo_bi();

-- Regla 16: catálogos con historial no se eliminan; se dan de baja.
create function trg_producto_bd() returns trigger language plpgsql as $$
begin
  if exists (select 1 from lote where id_producto = old.id_producto) then
    raise exception 'El producto "%" tiene lotes registrados. Use la baja lógica.', old.nombre using errcode = 'P0001';
  end if;
  return old;
end $$;
create trigger trg_producto_bd before delete on producto for each row execute function trg_producto_bd();

create function trg_proveedor_bd() returns trigger language plpgsql as $$
begin
  if exists (select 1 from lote where id_proveedor = old.id_proveedor) then
    raise exception 'El proveedor "%" ya entregó lotes. Use la baja lógica.', old.nombre using errcode = 'P0001';
  end if;
  return old;
end $$;
create trigger trg_proveedor_bd before delete on proveedor for each row execute function trg_proveedor_bd();

create function trg_cliente_bd() returns trigger language plpgsql as $$
begin
  if exists (select 1 from venta where id_cliente = old.id_cliente) then
    raise exception 'El cliente "%" tiene ventas registradas. Use la baja lógica.', old.nombre using errcode = 'P0001';
  end if;
  return old;
end $$;
create trigger trg_cliente_bd before delete on cliente for each row execute function trg_cliente_bd();

-- Regla 6: lote nuevo con caducidad futura, producto y proveedor activos.
create function trg_lote_bi() returns trigger language plpgsql as $$
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
create trigger trg_lote_bi before insert on lote for each row execute function trg_lote_bi();

-- Reglas 5 y 7: la existencia y el estado solo cambian por procesos del sistema;
-- cantidad, costo y producto solo se corrigen si el lote no tiene movimientos.
create function trg_lote_bu() returns trigger language plpgsql as $$
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
create trigger trg_lote_bu before update on lote for each row execute function trg_lote_bu();

-- Un lote solo se elimina si fue una captura errónea (sin movimientos).
create function trg_lote_bd() returns trigger language plpgsql as $$
begin
  if exists (select 1 from movimiento where id_lote = old.id_lote) then
    raise exception 'El lote % tiene movimientos y no se puede eliminar. Puede bloquearlo.', old.codigo_lote using errcode = 'P0001';
  end if;
  return old;
end $$;
create trigger trg_lote_bd before delete on lote for each row execute function trg_lote_bd();

-- Reglas 3 y 13: validaciones de cada movimiento.
create function trg_mov_bi() returns trigger language plpgsql as $$
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
create trigger trg_mov_bi before insert on movimiento for each row execute function trg_mov_bi();

-- El movimiento descuenta o suma la existencia y recalcula el estado del lote.
create function trg_mov_ai() returns trigger language plpgsql as $$
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
create trigger trg_mov_ai after insert on movimiento for each row execute function trg_mov_ai();

-- Regla 8: los movimientos son inmutables.
create function trg_mov_inmutable() returns trigger language plpgsql as $$
begin
  raise exception 'Los movimientos no se editan ni se borran: registre un movimiento compensatorio.' using errcode = 'P0001';
end $$;
create trigger trg_mov_bu before update on movimiento for each row execute function trg_mov_inmutable();
create trigger trg_mov_bd before delete on movimiento for each row execute function trg_mov_inmutable();

-- Regla 9: las ventas no se eliminan; se cancelan una sola vez.
create function trg_venta_bu() returns trigger language plpgsql as $$
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
create trigger trg_venta_bu before update on venta for each row execute function trg_venta_bu();

create function trg_venta_bd() returns trigger language plpgsql as $$
begin
  raise exception 'Las ventas no se eliminan: se cancelan con motivo.' using errcode = 'P0001';
end $$;
create trigger trg_venta_bd before delete on venta for each row execute function trg_venta_bd();

-- =====================================================================
-- 4. AUDITORÍA AUTOMÁTICA (regla 17)
-- =====================================================================
create function trg_auditar() returns trigger language plpgsql as $$
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
create trigger trg_aud_producto  after insert or update or delete on producto  for each row execute function trg_auditar('id_producto');
create trigger trg_aud_proveedor after insert or update or delete on proveedor for each row execute function trg_auditar('id_proveedor');
create trigger trg_aud_cliente   after insert or update or delete on cliente   for each row execute function trg_auditar('id_cliente');
create trigger trg_aud_lote      after insert or update or delete on lote      for each row execute function trg_auditar('id_lote');
create trigger trg_aud_venta     after insert or update or delete on venta     for each row execute function trg_auditar('id_venta');
create trigger trg_aud_usuario   after insert or update or delete on usuario   for each row execute function trg_auditar('id_usuario');

-- =====================================================================
-- 5. VISTAS (cálculos derivados del documento, sección 9)
-- =====================================================================
create view v_lote_detalle with (security_invoker = on) as
select l.id_lote, l.codigo_lote, l.id_producto, p.sku, p.nombre as producto, u.clave as unidad,
       l.id_proveedor, pr.nombre as proveedor, l.fecha_caducidad, l.fecha_entrada,
       l.cantidad_inicial, l.cantidad_disponible, l.costo_unitario, l.estado, l.motivo_bloqueo,
       (l.fecha_caducidad - fn_hoy()) as dias_restantes,
       case when l.estado <> 'VIGENTE' then l.estado::text
            when l.fecha_caducidad - fn_hoy() < 30 then 'ROJO'
            when l.fecha_caducidad - fn_hoy() <= 60 then 'AMARILLO'
            else 'VERDE' end as semaforo,
       round(l.cantidad_disponible * l.costo_unitario, 2) as valor_existencia,
       (l.estado = 'VIGENTE' and l.fecha_caducidad - fn_hoy() >= p.dias_minimos_venta) as vendible,
       exists (select 1 from movimiento m where m.id_lote = l.id_lote) as tiene_movimientos
  from lote l
  join producto p       on p.id_producto = l.id_producto
  join unidad_medida u  on u.id_unidad = p.id_unidad
  join proveedor pr     on pr.id_proveedor = l.id_proveedor;

create view v_producto with (security_invoker = on) as
select p.id_producto, p.sku, p.nombre, p.id_unidad, u.clave as unidad, p.precio_venta,
       p.stock_minimo, p.dias_minimos_venta, p.activo, p.creado_en,
       coalesce(s.stock_vigente, 0)  as stock_vigente,
       coalesce(s.stock_vendible, 0) as stock_vendible,
       coalesce(s.lotes, 0)          as lotes,
       (coalesce(s.stock_vigente, 0) < p.stock_minimo) as alerta_reorden,
       p.imagen_path
  from producto p
  join unidad_medida u on u.id_unidad = p.id_unidad
  left join lateral (
    select count(*) as lotes,
           sum(l.cantidad_disponible) filter (where l.estado = 'VIGENTE' and l.fecha_caducidad >= fn_hoy()) as stock_vigente,
           sum(l.cantidad_disponible) filter (where l.estado = 'VIGENTE'
                                              and l.fecha_caducidad - fn_hoy() >= p.dias_minimos_venta) as stock_vendible
      from lote l where l.id_producto = p.id_producto) s on true;

create view v_proveedor with (security_invoker = on) as
select pr.*, (select count(*) from lote l where l.id_proveedor = pr.id_proveedor) as lotes
  from proveedor pr;

create view v_cliente with (security_invoker = on) as
select c.*,
       (select count(*) from venta v where v.id_cliente = c.id_cliente and v.estado = 'REGISTRADA') as ventas
  from cliente c;

create view v_venta_resumen with (security_invoker = on) as
select v.id_venta, fn_folio(v.id_venta) as folio, v.fecha, v.id_cliente, c.nombre as cliente,
       v.estado, v.motivo_cancelacion, v.fecha_cancelacion, v.usuario,
       coalesce(sum(m.cantidad * m.precio_unitario), 0)::numeric(12,2)                       as total,
       coalesce(sum(m.cantidad * (m.precio_unitario - l.costo_unitario)), 0)::numeric(12,2)  as margen_bruto,
       coalesce(sum(m.cantidad), 0)  as unidades,
       count(m.id_movimiento)        as lotes_usados
  from venta v
  join cliente c on c.id_cliente = v.id_cliente
  left join movimiento m on m.id_venta = v.id_venta and m.tipo = 'VENTA'
  left join lote l on l.id_lote = m.id_lote
 group by v.id_venta, c.nombre;

create view v_movimiento_detalle with (security_invoker = on) as
select m.id_movimiento, m.fecha, m.tipo, m.cantidad, m.precio_unitario, m.motivo, m.usuario,
       m.id_lote, l.codigo_lote, l.fecha_caducidad, p.id_producto, p.sku, p.nombre as producto,
       m.id_venta, case when m.id_venta is null then null else fn_folio(m.id_venta) end as folio,
       c.nombre as cliente
  from movimiento m
  join lote l      on l.id_lote = m.id_lote
  join producto p  on p.id_producto = l.id_producto
  left join venta v   on v.id_venta = m.id_venta
  left join cliente c on c.id_cliente = v.id_cliente;

-- Trazabilidad: qué clientes recibieron cada lote (ventas no canceladas, netas de devoluciones).
create view v_trazabilidad with (security_invoker = on) as
select l.id_lote, l.codigo_lote, p.nombre as producto, c.id_cliente, c.nombre as cliente,
       c.telefono, fn_folio(v.id_venta) as folio, v.fecha, m.cantidad, v.estado
  from movimiento m
  join venta v    on v.id_venta = m.id_venta
  join cliente c  on c.id_cliente = v.id_cliente
  join lote l     on l.id_lote = m.id_lote
  join producto p on p.id_producto = l.id_producto
 where m.tipo = 'VENTA';

create view v_tablero with (security_invoker = on) as
select
  coalesce(sum(valor_existencia) filter (where semaforo = 'ROJO'), 0)                         as valor_en_riesgo,
  coalesce(sum(valor_existencia) filter (where estado in ('CADUCADO','BLOQUEADO')), 0)        as valor_no_vendible,
  coalesce(sum(valor_existencia) filter (where estado = 'VIGENTE'), 0)                         as valor_vigente,
  count(*) filter (where semaforo = 'ROJO'     and cantidad_disponible > 0)                    as lotes_rojo,
  count(*) filter (where semaforo = 'AMARILLO' and cantidad_disponible > 0)                    as lotes_amarillo,
  count(*) filter (where semaforo = 'VERDE'    and cantidad_disponible > 0)                    as lotes_verde,
  count(*) filter (where estado = 'CADUCADO'   and cantidad_disponible > 0)                    as lotes_caducados,
  count(*) filter (where estado = 'BLOQUEADO')                                                 as lotes_bloqueados,
  (select count(*) from v_producto where activo and alerta_reorden)                            as productos_reorden,
  (select coalesce(sum(total), 0) from v_venta_resumen
    where estado = 'REGISTRADA' and (fecha at time zone 'America/Mexico_City')::date = fn_hoy()) as ventas_hoy
  from v_lote_detalle
having fn_tiene_permiso('tablero.ver');   -- solo quien tiene permiso ve los indicadores

create view v_auditoria with (security_invoker = on) as
select * from auditoria;

-- =====================================================================
-- 6. FUNCIONES RPC
--  La app solo escribe a través de estas funciones (SECURITY DEFINER),
--  así cada operación es una transacción completa y queda firmada.
-- =====================================================================

-- ---------- Catálogos ----------
create function unidad_guardar(p_clave text, p_nombre text, p_usuario text default null)
returns smallint language plpgsql security definer set search_path = public as $$
declare v_id smallint;
begin
  perform fn_set_usuario(p_usuario); perform fn_exigir('catalogo.editar');
  insert into unidad_medida (clave, nombre) values (upper(trim(p_clave)), trim(p_nombre)) returning id_unidad into v_id;
  return v_id;
end $$;

create function producto_guardar(p_id int, p_sku text, p_nombre text, p_id_unidad int,
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

-- Asigna o quita (null) la foto del producto. El archivo se sube a Storage desde la app.
create function producto_imagen(p_id int, p_imagen_path text, p_usuario text default null) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform fn_set_usuario(p_usuario); perform fn_exigir('catalogo.editar');
  if p_imagen_path is not null and p_imagen_path !~ '^[A-Za-z0-9._/-]{3,200}$' then
    raise exception 'Nombre de archivo de imagen no válido.' using errcode = 'P0001';
  end if;
  update producto set imagen_path = p_imagen_path where id_producto = p_id;
  if not found then raise exception 'El producto no existe.' using errcode = 'P0001'; end if;
end $$;

create function producto_baja(p_id int, p_usuario text default null) returns void
language plpgsql security definer set search_path = public as $$
begin perform fn_set_usuario(p_usuario); perform fn_exigir('catalogo.editar'); update producto set activo = false where id_producto = p_id; end $$;

create function producto_reactivar(p_id int, p_usuario text default null) returns void
language plpgsql security definer set search_path = public as $$
begin perform fn_set_usuario(p_usuario); perform fn_exigir('catalogo.editar'); update producto set activo = true where id_producto = p_id; end $$;

create function producto_eliminar(p_id int, p_usuario text default null) returns void
language plpgsql security definer set search_path = public as $$
begin perform fn_set_usuario(p_usuario); perform fn_exigir('registros.eliminar'); delete from producto where id_producto = p_id; end $$;

create function proveedor_guardar(p_id int, p_rfc text, p_nombre text, p_telefono text, p_usuario text default null)
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

create function proveedor_baja(p_id int, p_usuario text default null) returns void
language plpgsql security definer set search_path = public as $$
begin perform fn_set_usuario(p_usuario); perform fn_exigir('catalogo.editar'); update proveedor set activo = false where id_proveedor = p_id; end $$;

create function proveedor_reactivar(p_id int, p_usuario text default null) returns void
language plpgsql security definer set search_path = public as $$
begin perform fn_set_usuario(p_usuario); perform fn_exigir('catalogo.editar'); update proveedor set activo = true where id_proveedor = p_id; end $$;

create function proveedor_eliminar(p_id int, p_usuario text default null) returns void
language plpgsql security definer set search_path = public as $$
begin perform fn_set_usuario(p_usuario); perform fn_exigir('registros.eliminar'); delete from proveedor where id_proveedor = p_id; end $$;

create function cliente_guardar(p_id int, p_nombre text, p_rfc text, p_telefono text, p_correo text, p_usuario text default null)
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

create function cliente_baja(p_id int, p_usuario text default null) returns void
language plpgsql security definer set search_path = public as $$
begin perform fn_set_usuario(p_usuario); perform fn_exigir('clientes.editar'); update cliente set activo = false where id_cliente = p_id; end $$;

create function cliente_reactivar(p_id int, p_usuario text default null) returns void
language plpgsql security definer set search_path = public as $$
begin perform fn_set_usuario(p_usuario); perform fn_exigir('clientes.editar'); update cliente set activo = true where id_cliente = p_id; end $$;

create function cliente_eliminar(p_id int, p_usuario text default null) returns void
language plpgsql security definer set search_path = public as $$
begin perform fn_set_usuario(p_usuario); perform fn_exigir('registros.eliminar'); delete from cliente where id_cliente = p_id; end $$;

-- ---------- Lotes ----------
create function lote_alta(p_id_producto int, p_id_proveedor int, p_codigo_lote text, p_fecha_caducidad date,
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

create function lote_modificar(p_id int, p_id_producto int, p_id_proveedor int, p_codigo_lote text,
  p_fecha_caducidad date, p_cantidad int, p_costo_unitario numeric, p_usuario text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform fn_set_usuario(p_usuario); perform fn_exigir('lotes.editar');
  update lote set id_producto = p_id_producto, id_proveedor = p_id_proveedor, codigo_lote = p_codigo_lote,
         fecha_caducidad = p_fecha_caducidad, cantidad_inicial = p_cantidad, costo_unitario = p_costo_unitario
   where id_lote = p_id;
  if not found then raise exception 'El lote no existe.' using errcode = 'P0001'; end if;
end $$;

create function lote_bloquear(p_id int, p_motivo text, p_usuario text default null) returns void
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

create function lote_desbloquear(p_id int, p_usuario text default null) returns void
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

create function lote_eliminar(p_id int, p_usuario text default null) returns void
language plpgsql security definer set search_path = public as $$
begin perform fn_set_usuario(p_usuario); perform fn_exigir('registros.eliminar'); delete from lote where id_lote = p_id; end $$;

create function registrar_merma(p_id_lote int, p_cantidad int, p_motivo text, p_usuario text default null)
returns bigint language plpgsql security definer set search_path = public as $$
declare v_id bigint;
begin
  perform fn_set_usuario(p_usuario); perform fn_exigir('inventario.ajustar');
  perform 1 from lote where id_lote = p_id_lote for update;
  insert into movimiento (id_lote, tipo, cantidad, motivo) values (p_id_lote, 'MERMA', p_cantidad, p_motivo)
  returning id_movimiento into v_id;
  return v_id;
end $$;

create function registrar_ajuste(p_id_lote int, p_positivo boolean, p_cantidad int, p_motivo text, p_usuario text default null)
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

-- ---------- Algoritmo FEFO (sección 6) ----------
-- Devuelve de qué lotes sale cada unidad. Con p_bloquear = true usa FOR UPDATE (regla 12).
create function fn_fefo_asignar(p_id_producto int, p_cantidad int, p_bloquear boolean)
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

-- p_lineas: [{"id_producto": 1, "cantidad": 50}, ...]
create function simular_fefo(p_lineas jsonb) returns jsonb
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

-- Venta completa en una sola transacción (regla 11): o se registra todo o nada.
create function venta_registrar(p_id_cliente int, p_lineas jsonb, p_usuario text default null)
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

-- Regla 10: cancelar devuelve cada unidad al lote exacto del que salió.
create function venta_cancelar(p_id_venta bigint, p_motivo text, p_usuario text default null)
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

-- Regla 14: pasa a CADUCADO los lotes vencidos. Devuelve cuántos cambió.
create function marcar_caducados() returns int
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

-- =====================================================================
-- 7. REPORTEADOR
--  Funciones de solo lectura que alimentan el módulo Reportes.
--  Los periodos usan la fecha local de la operación (America/Mexico_City).
-- =====================================================================

-- Ventas del periodo, una fila por venta.
create function rpt_ventas(p_desde date, p_hasta date, p_incluir_canceladas boolean default false)
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

-- Importe vendido por día (incluye los días sin ventas, para la gráfica).
create function rpt_ventas_dia(p_desde date, p_hasta date)
returns table (dia date, ventas bigint, importe numeric, margen numeric)
language sql stable as $$
  select fn_exigir('reportes.ver');
  select d::date, count(v.id_venta), coalesce(sum(v.total), 0)::numeric(12,2), coalesce(sum(v.margen_bruto), 0)::numeric(12,2)
    from generate_series(p_desde, p_hasta, interval '1 day') d
    left join v_venta_resumen v
      on (v.fecha at time zone 'America/Mexico_City')::date = d::date and v.estado = 'REGISTRADA'
   group by d order by d;
$$;

-- Ventas por producto (solo ventas no canceladas).
create function rpt_ventas_producto(p_desde date, p_hasta date)
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

-- Ventas por cliente.
create function rpt_ventas_cliente(p_desde date, p_hasta date)
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

-- Inventario valorizado por producto, a hoy.
create function rpt_inventario()
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

-- Lotes con existencia que vencen dentro de N días (incluye los ya caducados).
create function rpt_por_caducar(p_dias int)
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

-- Mermas y ajustes del periodo, valuados a costo.
create function rpt_mermas_ajustes(p_desde date, p_hasta date)
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

-- Entradas de mercancía por proveedor.
create function rpt_entradas_proveedor(p_desde date, p_hasta date)
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

-- Kardex: entradas y salidas de un producto (o de todos) con saldo acumulado.
create function rpt_kardex(p_desde date, p_hasta date, p_id_producto int default null)
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

-- =====================================================================
-- 7b. USUARIOS Y PERMISOS
-- =====================================================================

-- Perfil del usuario con sesión. Solo entra quien fue dado de alta por un
-- administrador (se liga por correo la primera vez). Excepción: si la
-- instalación todavía no tiene administrador, la primera cuenta lo será.
create function mi_perfil() returns jsonb language plpgsql security definer set search_path = public as $$
declare c jsonb := nullif(current_setting('request.jwt.claims', true), '')::jsonb; v usuario%rowtype; r rol%rowtype;
begin
  if fn_uid() is null then raise exception 'Inicia sesión para continuar.' using errcode = 'P0001'; end if;
  select * into v from usuario where auth_id = fn_uid();
  if not found then
    -- ¿Un administrador lo dio de alta con este correo?
    update usuario set auth_id = fn_uid()
     where auth_id is null and lower(email) = lower(coalesce(c ->> 'email', ''))
    returning * into v;
    if v.id_usuario is null then
      if exists (select 1 from usuario u join rol_permiso rp on rp.id_rol = u.id_rol
                  where u.activo and rp.permiso = 'usuarios.administrar') then
        raise exception 'Tu cuenta no está autorizada en LoteSmart. Pide a un administrador que te dé de alta.' using errcode = 'P0001';
      end if;
      insert into usuario (auth_id, email, nombre, id_rol)
      values (fn_uid(), coalesce(c ->> 'email', 'sin-correo'),
              coalesce(nullif(trim(c -> 'user_metadata' ->> 'nombre'), ''), split_part(coalesce(c ->> 'email', 'usuario'), '@', 1)),
              (select id_rol from rol where clave = 'ADMIN'))
      returning * into v;
    end if;
  end if;
  select * into r from rol where id_rol = v.id_rol;
  return jsonb_build_object('id_usuario', v.id_usuario, 'nombre', v.nombre, 'email', v.email, 'activo', v.activo,
    'rol', r.clave, 'rol_nombre', r.nombre,
    'permisos', (select coalesce(jsonb_agg(permiso order by permiso), '[]'::jsonb) from rol_permiso where id_rol = v.id_rol));
end $$;

-- Alta de un usuario (solo administradores). Si la persona ya tiene cuenta
-- en Supabase Auth con ese correo, queda ligada de inmediato.
create function usuario_crear(p_email text, p_nombre text, p_id_rol int, p_usuario text default null)
returns int language plpgsql security definer set search_path = public as $$
declare v_id int; v_auth uuid; v_email text := lower(trim(p_email));
begin
  perform fn_set_usuario(p_usuario); perform fn_exigir('usuarios.administrar');
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'El correo no tiene un formato válido.' using errcode = 'P0001';
  end if;
  if exists (select 1 from usuario where lower(email) = v_email) then
    raise exception 'Ya existe un usuario con el correo %.', v_email using errcode = 'P0001';
  end if;
  if to_regclass('auth.users') is not null then
    execute 'select id from auth.users where lower(email) = $1 limit 1' into v_auth using v_email;
  end if;
  insert into usuario (auth_id, email, nombre, id_rol) values (v_auth, v_email, trim(p_nombre), p_id_rol)
  returning id_usuario into v_id;
  return v_id;
end $$;

-- Elimina un alta que todavía no se activó (para usuarios activos, desactivar).
create function usuario_eliminar(p_id_usuario int, p_usuario text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform fn_set_usuario(p_usuario); perform fn_exigir('usuarios.administrar');
  delete from usuario where id_usuario = p_id_usuario and auth_id is null;
  if not found then
    raise exception 'Solo se pueden eliminar altas pendientes. A un usuario con cuenta, desactívalo.' using errcode = 'P0001';
  end if;
end $$;

-- Cada quien puede cambiar su propio nombre de firma.
create function mi_nombre(p_nombre text) returns void language plpgsql security definer set search_path = public as $$
begin
  perform fn_exigir(null);
  update usuario set nombre = trim(p_nombre) where auth_id = fn_uid();
end $$;

create function usuario_actualizar(p_id_usuario int, p_nombre text, p_id_rol int, p_activo boolean, p_usuario text default null)
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

create function rol_permiso_cambiar(p_id_rol int, p_permiso text, p_conceder boolean, p_usuario text default null)
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

-- =====================================================================
-- 8. SEGURIDAD E INICIO DE SESIÓN
--  · Solo usuarios con sesión iniciada (rol "authenticated" de Supabase Auth)
--    pueden ver o modificar datos. El rol "anon" (sin sesión) no ve nada.
--  · RLS activado: con sesión se puede LEER; las escrituras pasan solo por las
--    funciones RPC, que validan y firman cada operación con el usuario.
--  · Los usuarios se crean en Authentication → Users o desde la pantalla
--    "Crear cuenta" de la app.
-- =====================================================================
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin; end if;
end $$;

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
    'mi_perfil()', 'mi_nombre(text)', 'usuario_actualizar(int, text, int, boolean, text)', 'rol_permiso_cambiar(int, text, boolean, text)',
    'usuario_crear(text, text, int, text)', 'usuario_eliminar(int, text)'
  ] loop
    execute format('revoke execute on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;

-- =====================================================================
-- Fotos de productos: bucket público "productos" en Supabase Storage.
-- Cualquiera puede VER las fotos (para mostrarlas en la app); solo
-- usuarios con sesión pueden subir, reemplazar o borrar. Máx. 2 MB, solo imágenes.
-- =====================================================================
do $$
begin
  if to_regclass('storage.buckets') is null then
    raise notice 'Storage no disponible (fuera de Supabase): se omite el bucket de fotos.';
    return;
  end if;
  insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
  values ('productos', 'productos', true, 2097152, array['image/jpeg','image/png','image/webp'])
  on conflict (id) do update set public = true, file_size_limit = 2097152,
                                 allowed_mime_types = array['image/jpeg','image/png','image/webp'];
  execute 'drop policy if exists "lotesmart fotos leer" on storage.objects';
  execute 'drop policy if exists "lotesmart fotos subir" on storage.objects';
  execute 'drop policy if exists "lotesmart fotos cambiar" on storage.objects';
  execute 'drop policy if exists "lotesmart fotos borrar" on storage.objects';
  execute $p$create policy "lotesmart fotos leer" on storage.objects for select using (bucket_id = 'productos')$p$;
  execute $p$create policy "lotesmart fotos subir" on storage.objects for insert to authenticated with check (bucket_id = 'productos')$p$;
  execute $p$create policy "lotesmart fotos cambiar" on storage.objects for update to authenticated using (bucket_id = 'productos') with check (bucket_id = 'productos')$p$;
  execute $p$create policy "lotesmart fotos borrar" on storage.objects for delete to authenticated using (bucket_id = 'productos')$p$;
end $$;

-- =====================================================================
-- Al crearse una cuenta en Supabase Auth se liga con el alta que hizo el
-- administrador (mismo correo). Una cuenta sin alta NO recibe acceso.
-- Las cuentas que ya existían al instalar se registran aquí mismo.
-- =====================================================================
create function fn_perfil_desde_auth() returns trigger language plpgsql security definer set search_path = public as $$
begin
  update public.usuario set auth_id = new.id where auth_id is null and lower(email) = lower(coalesce(new.email, ''));
  if not found and not exists (select 1 from public.usuario u join public.rol_permiso rp on rp.id_rol = u.id_rol
                                where u.activo and rp.permiso = 'usuarios.administrar') then
    -- Instalación nueva sin administrador: la primera cuenta lo será.
    insert into public.usuario (auth_id, email, nombre, id_rol)
    values (new.id, coalesce(new.email, 'sin-correo'),
            coalesce(nullif(trim(new.raw_user_meta_data ->> 'nombre'), ''), split_part(coalesce(new.email, 'usuario'), '@', 1)),
            (select id_rol from public.rol where clave = 'ADMIN'))
    on conflict do nothing;
  end if;
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
    on conflict do nothing;
  end loop;
end $$;

-- =====================================================================
-- 9. DATOS DE PRUEBA (fechas relativas a hoy: la demo siempre funciona)
-- =====================================================================
select set_config('app.usuario', 'instalacion', false);

insert into unidad_medida (clave, nombre) values
  ('PIEZA','Pieza'), ('CAJA','Caja'), ('LATA','Lata'), ('LITRO','Litro'), ('KG','Kilogramo'), ('FRASCO','Frasco');

insert into proveedor (rfc, nombre, telefono) values
  ('LCA850101AB1', 'Lácteos del Carmen S.A. de C.V.', '938 112 3344'),
  ('FSU990315KZ2', 'Farmacéutica del Sureste S.A.',   '999 455 1020'),
  ('ACA010720M33', 'Abarrotes Campeche S.A.',          '981 816 7788');

insert into cliente (nombre, rfc, telefono, correo) values
  ('Tienda La Esperanza',     'TES120405HT1', '938 381 2210', 'compras@laesperanza.mx'),
  ('Farmacia San Román',      'FSR090911QP4', '938 384 5501', null),
  ('Cocina Económica Doña Mary', null,        '938 120 9090', null),
  ('Hospital General del Carmen', 'HGC780101AA0', '938 382 0000', 'almacen@hgc.gob.mx');

insert into producto (sku, nombre, id_unidad, precio_venta, stock_minimo, dias_minimos_venta) values
  ('LEC-001', 'Leche entera 1 L',        (select id_unidad from unidad_medida where clave = 'LITRO'), 28.50, 60, 3),
  ('PAR-500', 'Paracetamol 500 mg c/20', (select id_unidad from unidad_medida where clave = 'CAJA'),  45.00, 50, 30),
  ('SOP-410', 'Sopa de verduras',        (select id_unidad from unidad_medida where clave = 'LATA'),  22.00, 40, 15),
  ('YOG-250', 'Yogurt natural 250 g',    (select id_unidad from unidad_medida where clave = 'PIEZA'), 16.00, 30, 2),
  ('ARR-1KG', 'Arroz blanco 1 kg',       (select id_unidad from unidad_medida where clave = 'KG'),    32.00, 25, 30);

-- Permite cargar un lote ya vencido (SO-4410) solo durante la instalación.
select set_config('lotesmart.seed', '1', false);
insert into lote (id_producto, id_proveedor, codigo_lote, fecha_caducidad, cantidad_inicial, cantidad_disponible, costo_unitario)
select p.id_producto, pr.id_proveedor, x.codigo, fn_hoy() + x.dias, x.cant, x.cant, x.costo
  from (values
    ('LEC-001','LCA850101AB1','LG-2410-A',    6,  40, 19.00),
    ('LEC-001','LCA850101AB1','LG-2410-B',   14,  35, 19.00),
    ('LEC-001','LCA850101AB1','LG-2411-C',   45, 100, 19.50),
    ('PAR-500','FSU990315KZ2','PA-77812',    25, 120, 21.00),
    ('PAR-500','FSU990315KZ2','PA-77901',    90,  80, 21.50),
    ('SOP-410','ACA010720M33','SO-4410',     -3,  24, 12.00),
    ('SOP-410','ACA010720M33','SO-4502',     70,  60, 12.50),
    ('YOG-250','LCA850101AB1','YG-0918',     38,  50,  9.00),
    ('ARR-1KG','ACA010720M33','AR-2026-11', 240,  20, 18.00)
  ) as x(sku, rfc, codigo, dias, cant, costo)
  join producto p   on p.sku = x.sku
  join proveedor pr on pr.rfc = x.rfc;
select set_config('lotesmart.seed', '', false);

select marcar_caducados();   -- SO-4410 pasa a CADUCADO

-- Venta V-000001: agota el lote LG-2410-A y lo deja en "Tienda La Esperanza".
select venta_registrar(
  (select id_cliente from cliente where nombre = 'Tienda La Esperanza'),
  jsonb_build_array(jsonb_build_object('id_producto', (select id_producto from producto where sku = 'LEC-001'), 'cantidad', 40)),
  'instalacion');

-- Avisa a la API de Supabase que hay tablas y funciones nuevas.
notify pgrst, 'reload schema';

-- Opcional: marcar caducados cada noche con pg_cron (Database → Extensions → pg_cron)
-- select cron.schedule('lotesmart-caducados', '5 6 * * *', $$select public.marcar_caducados()$$);
