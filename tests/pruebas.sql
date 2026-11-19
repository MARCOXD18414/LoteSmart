-- =====================================================================
--  LoteSmart · Pruebas de integración (sección 13 del documento)
--  Ejecútalo en Supabase → SQL Editor DESPUÉS de lotesmart_supabase.sql.
--  Resultado esperado: "34 de 34 aprobadas".
--  Modifica datos: al terminar vuelve a ejecutar lotesmart_supabase.sql.
-- =====================================================================
drop table if exists pg_temp.r;
create temp table r (n serial, prueba text, ok boolean, detalle text);
grant all on r to anon, authenticated;
grant usage on sequence r_n_seq to anon, authenticated;

create or replace function pg_temp.espera_error(p_prueba text, p_sql text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
    insert into r (prueba, ok, detalle) values (p_prueba, false, 'NO falló');
  exception when others then
    insert into r (prueba, ok, detalle) values (p_prueba, true, sqlerrm);
  end;
end $$;
create or replace function pg_temp.espera(p_prueba text, p_cond boolean, p_det text) returns void language sql as
$$ insert into r (prueba, ok, detalle) values (p_prueba, coalesce(p_cond, false), p_det) $$;

do $$
declare v_antes bigint; v_sim jsonb; v_v2 bigint; v_leche int; v_para int; v_yog int;
begin
  select id_producto into v_leche from producto where sku = 'LEC-001';
  select id_producto into v_para  from producto where sku = 'PAR-500';
  select id_producto into v_yog   from producto where sku = 'YOG-250';
  -- Sin sesión (rol anon) no se puede ver ni hacer nada.
  set local role anon;
  perform pg_temp.espera_error('Sin sesión no se leen datos', $q$select count(*) from v_producto$q$);
  perform pg_temp.espera_error('Sin sesión no se registran ventas', $q$select venta_registrar(1, '[{"id_producto":1,"cantidad":1}]', 'x')$q$);
  reset role;

  -- Con sesión: rol authenticated y token de Supabase Auth (firma con el nombre del usuario).
  perform set_config('request.jwt.claims', '{"email":"ana@lotesmart.mx","user_metadata":{"nombre":"Ana López"}}', true);
  set local role authenticated;

  perform pg_temp.espera_error('Lote con caducidad de ayer',
    format($q$select lote_alta(%s, 1, 'X-AYER', fn_hoy() - 1, 10, 5, 'test')$q$, v_leche));
  perform pg_temp.espera_error('Lote con código repetido para el mismo producto',
    format($q$select lote_alta(%s, 1, 'lg-2410-b', fn_hoy() + 30, 10, 5, 'test')$q$, v_leche));

  select count(*) into v_antes from venta;
  perform pg_temp.espera_error('Vender más de lo disponible',
    format($q$select venta_registrar(1, '[{"id_producto":%s,"cantidad":10},{"id_producto":%s,"cantidad":90}]', 'test')$q$, v_leche, v_para));
  perform pg_temp.espera('Rollback: sin venta parcial',
    (select count(*) from venta) = v_antes and (select cantidad_disponible from lote where codigo_lote = 'LG-2410-B') = 35, 'ventas y existencias intactas');

  perform pg_temp.espera_error('Merma mayor a la existencia',
    $q$select registrar_merma((select id_lote from lote where codigo_lote = 'LG-2410-B'), 999, 'rota', 'test')$q$);
  perform pg_temp.espera_error('Corregir cantidad de un lote con ventas',
    $q$select lote_modificar(l.id_lote, l.id_producto, l.id_proveedor, l.codigo_lote, fn_hoy() + 6, 999, 19, 'test') from lote l where codigo_lote = 'LG-2410-A'$q$);
  perform pg_temp.espera_error('Eliminar proveedor con lotes', $q$select proveedor_eliminar(1, 'test')$q$);

  perform producto_baja(v_yog, 'test');
  perform pg_temp.espera_error('Baja de producto y recibir lote nuevo',
    format($q$select lote_alta(%s, 1, 'YG-NUEVO', fn_hoy() + 30, 10, 5, 'test')$q$, v_yog));
  perform pg_temp.espera_error('Paracetamol: vender 90 con vida útil mínima',
    format($q$select venta_registrar(2, '[{"id_producto":%s,"cantidad":90}]', 'test')$q$, v_para));
  perform pg_temp.espera_error('Eliminar producto con lotes', format($q$select producto_eliminar(%s, 'test')$q$, v_yog));

  -- FEFO en vivo: 50 litros de leche
  v_sim := simular_fefo(jsonb_build_array(jsonb_build_object('id_producto', v_leche, 'cantidad', 50))) -> 0 -> 'asignaciones';
  perform pg_temp.espera('Simular FEFO 50 L = 35 de B + 15 de C',
    (select array_agg((e->>'codigo_lote') || ':' || (e->>'tomar') order by e->>'codigo_lote') from jsonb_array_elements(v_sim) e)
      = array['LG-2410-B:35', 'LG-2411-C:15'], v_sim::text);
  v_v2 := venta_registrar(2, jsonb_build_array(jsonb_build_object('id_producto', v_leche, 'cantidad', 50)), 'demo');
  perform pg_temp.espera('Venta 50 L genera 2 movimientos y B queda AGOTADO',
    (select count(*) from movimiento where id_venta = v_v2) = 2
    and (select estado from lote where codigo_lote = 'LG-2410-B') = 'AGOTADO'
    and (select cantidad_disponible from lote where codigo_lote = 'LG-2411-C') = 85, fn_folio(v_v2));

  perform pg_temp.espera_error('Con sesión tampoco se escribe directo en tablas', $q$insert into unidad_medida (clave, nombre) values ('XX', 'x')$q$);
  perform pg_temp.espera_error('Las funciones internas no se exponen', $q$select * from fn_fefo_asignar(1, 1, true)$q$);

  -- Integridad desde la BD, como administrador (sin pasar por la app)
  reset role;
  perform pg_temp.espera_error('UPDATE directo de existencia', $q$update lote set cantidad_disponible = 999 where codigo_lote = 'LG-2411-C'$q$);
  perform pg_temp.espera_error('DELETE de movimientos', $q$delete from movimiento$q$);
  perform pg_temp.espera_error('DELETE de venta', $q$delete from venta where id_venta = 1$q$);
  perform pg_temp.espera_error('Cambiar estado a mano', $q$update lote set estado = 'VIGENTE' where codigo_lote = 'SO-4410'$q$);
  set local role authenticated;

  -- Cancelación
  perform venta_cancelar(v_v2, 'Cliente devolvió el pedido', 'demo');
  perform pg_temp.espera('Cancelar devuelve a cada lote y B vuelve a VIGENTE',
    (select estado from lote where codigo_lote = 'LG-2410-B') = 'VIGENTE'
    and (select cantidad_disponible from lote where codigo_lote = 'LG-2410-B') = 35
    and (select cantidad_disponible from lote where codigo_lote = 'LG-2411-C') = 100
    and (select count(*) from movimiento where id_venta = v_v2 and tipo = 'DEVOLUCION') = 2, 'ok');
  perform pg_temp.espera_error('Cancelar dos veces la misma venta', format($q$select venta_cancelar(%s, 'otra', 'demo')$q$, v_v2));

  -- Trazabilidad, bloqueo, mermas y auditoría
  perform pg_temp.espera('Trazabilidad LG-2410-A → Tienda La Esperanza',
    exists (select 1 from v_trazabilidad where codigo_lote = 'LG-2410-A' and cliente = 'Tienda La Esperanza'), 'ok');
  perform lote_bloquear((select id_lote from lote where codigo_lote = 'LG-2411-C'), 'Retiro sanitario preventivo', 'demo');
  perform pg_temp.espera_error('No se vende de un lote bloqueado',
    format($q$select venta_registrar(1, '[{"id_producto":%s,"cantidad":40}]', 'test')$q$, v_leche));
  perform lote_desbloquear((select id_lote from lote where codigo_lote = 'LG-2411-C'), 'demo');
  perform registrar_ajuste((select id_lote from lote where codigo_lote = 'LG-2411-C'), false, 5, 'Conteo físico', 'demo');
  perform registrar_merma((select id_lote from lote where codigo_lote = 'SO-4410'), 4, 'Latas infladas', 'demo');
  perform pg_temp.espera('Merma sobre lote caducado permitida', (select cantidad_disponible from lote where codigo_lote = 'SO-4410') = 20, 'ok');
  perform pg_temp.espera('Auditoría registra bloqueo, cancelación y baja',
    (select count(*) from v_auditoria where accion in ('CAMBIO_ESTADO', 'CANCELACION', 'BAJA') and usuario = 'Ana López') >= 4,
    (select string_agg(distinct accion || '/' || usuario, ', ') from v_auditoria));

  perform pg_temp.espera('Alta de lote correcta', lote_alta((select id_producto from producto where sku = 'ARR-1KG'), 3, 'AR-PRUEBA', fn_hoy() + 100, 10, 18, 'test') is not null, 'alta');
  perform lote_modificar((select id_lote from lote where codigo_lote = 'AR-PRUEBA'), (select id_producto from producto where sku = 'ARR-1KG'), 3, 'AR-PRUEBA', fn_hoy() + 120, 15, 18.5, 'test');
  perform pg_temp.espera('Corrección sin movimientos ajusta disponible', (select cantidad_disponible from lote where codigo_lote = 'AR-PRUEBA') = 15, 'ok');
  perform lote_eliminar((select id_lote from lote where codigo_lote = 'AR-PRUEBA'), 'test');
  perform pg_temp.espera('Eliminación física de captura errónea', not exists (select 1 from lote where codigo_lote = 'AR-PRUEBA'), 'ok');
  perform pg_temp.espera('La firma sale del usuario con sesión, no del parámetro',
    (select usuario from movimiento order by id_movimiento desc limit 1) = 'Ana López', (select usuario from movimiento order by id_movimiento desc limit 1));

  -- Reportes
  perform pg_temp.espera('Reporte de ventas por producto', exists (select 1 from rpt_ventas_producto(fn_hoy() - 30, fn_hoy()) where sku = 'LEC-001' and unidades = 40), 'ok');
  perform pg_temp.espera('Reporte de ventas excluye canceladas', (select count(*) from rpt_ventas(fn_hoy() - 30, fn_hoy())) = 1
    and (select count(*) from rpt_ventas(fn_hoy() - 30, fn_hoy(), true)) = 2, 'ok');
  perform pg_temp.espera('Kardex cuadra con la existencia',
    (select saldo from rpt_kardex(fn_hoy() - 30, fn_hoy(), v_leche) with ordinality k order by k.ordinality desc limit 1)
      = (select sum(cantidad_disponible) from lote where id_producto = v_leche), 'ok');
  perform pg_temp.espera('Inventario valorizado = tablero',
    (select sum(valor_en_riesgo) from rpt_inventario()) = (select valor_en_riesgo from v_tablero), 'ok');
end $$;

select n, case when ok then 'APROBADA' else 'FALLÓ' end as estado, prueba, left(detalle, 120) as detalle
  from r order by n;
select count(*) filter (where ok) || ' de ' || count(*) || ' aprobadas' as resultado from r;
