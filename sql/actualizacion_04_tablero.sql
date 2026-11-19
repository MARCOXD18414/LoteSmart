-- =====================================================================
--  LoteSmart · Actualización 04: el tablero solo para administradores
--  NO borra datos. Ejecútalo una vez en Supabase → SQL Editor → Run
--  (después de actualizacion_03_roles.sql).
--  Crea el permiso "Ver el tablero" y se lo da solo al rol Administrador.
--  Se puede conceder a otros roles desde Usuarios y permisos.
-- =====================================================================
insert into permiso (clave, descripcion, orden)
values ('tablero.ver', 'Ver el tablero de caducidad y valor en riesgo', 0)
on conflict (clave) do nothing;

insert into rol_permiso (id_rol, permiso)
select id_rol, 'tablero.ver' from rol where clave = 'ADMIN'
on conflict do nothing;

create or replace view v_tablero with (security_invoker = on) as
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
having fn_tiene_permiso('tablero.ver');
grant select on v_tablero to authenticated;

notify pgrst, 'reload schema';
