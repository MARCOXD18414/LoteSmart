-- =====================================================================
--  LoteSmart · Actualización 01: auditoría legible
--  NO borra datos. Ejecútalo una vez en Supabase → SQL Editor → Run.
--  Desde ahora las altas y eliminaciones se guardan como "campo: valor"
--  en lugar de JSON. Los registros anteriores la app ya los muestra bien.
-- =====================================================================
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
