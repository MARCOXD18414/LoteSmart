-- =====================================================================
--  LoteSmart · Actualización 05: solo los administradores dan de alta usuarios
--  NO borra datos. Ejecútalo una vez en Supabase → SQL Editor → Run
--  (después de actualizacion_03_roles.sql).
--
--  · El administrador da de alta a cada persona (correo, nombre y rol)
--    desde Usuarios y permisos.
--  · Una cuenta que nadie dio de alta ya no recibe acceso, aunque se
--    registre por su cuenta.
-- =====================================================================
alter table usuario alter column auth_id drop not null;
create unique index if not exists uq_usuario_email on usuario (lower(email));

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

create or replace function mi_perfil() returns jsonb language plpgsql security definer set search_path = public as $$
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

create or replace function usuario_crear(p_email text, p_nombre text, p_id_rol int, p_usuario text default null)
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

create or replace function usuario_eliminar(p_id_usuario int, p_usuario text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform fn_set_usuario(p_usuario); perform fn_exigir('usuarios.administrar');
  delete from usuario where id_usuario = p_id_usuario and auth_id is null;
  if not found then
    raise exception 'Solo se pueden eliminar altas pendientes. A un usuario con cuenta, desactívalo.' using errcode = 'P0001';
  end if;
end $$;

create or replace function fn_perfil_desde_auth() returns trigger language plpgsql security definer set search_path = public as $$
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

revoke execute on function usuario_crear(text, text, int, text), usuario_eliminar(int, text) from public, anon;
grant execute on function usuario_crear(text, text, int, text), usuario_eliminar(int, text) to authenticated;

notify pgrst, 'reload schema';
