-- =====================================================================
--  LoteSmart · Actualización 02: fotos de productos
--  NO borra datos. Ejecútalo una vez en Supabase → SQL Editor → Run.
--  Agrega la columna de foto, la función para asignarla y el espacio
--  de almacenamiento (bucket "productos") con sus permisos.
-- =====================================================================
alter table producto add column if not exists imagen_path varchar(200);

create or replace view v_producto with (security_invoker = on) as
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

grant select on v_producto to authenticated;

-- Asigna o quita (null) la foto del producto. El archivo se sube a Storage desde la app.
create or replace function producto_imagen(p_id int, p_imagen_path text, p_usuario text default null) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform fn_set_usuario(p_usuario);
  if p_imagen_path is not null and p_imagen_path !~ '^[A-Za-z0-9._/-]{3,200}$' then
    raise exception 'Nombre de archivo de imagen no válido.' using errcode = 'P0001';
  end if;
  update producto set imagen_path = p_imagen_path where id_producto = p_id;
  if not found then raise exception 'El producto no existe.' using errcode = 'P0001'; end if;
end $$;

revoke execute on function producto_imagen(int, text, text) from public, anon;
grant execute on function producto_imagen(int, text, text) to authenticated;

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

notify pgrst, 'reload schema';
