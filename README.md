# LoteSmart · versión web con Supabase

Inventario por lotes con caducidad y despacho FEFO. Es la versión web del documento técnico (Java + MySQL), ahora con PostgreSQL en Supabase.

## Archivos

| Archivo | Qué es |
|---|---|
| `index.html` | La aplicación completa. Un solo archivo, sin instalar nada. |
| `sql/lotesmart_supabase.sql` | Base de datos: tablas, reglas, vistas, funciones, seguridad y datos de prueba. |
| `sql/actualizacion_01_auditoria.sql` | Actualización sin borrar datos: auditoría legible (solo si instalaste antes del 19/11/2026). |
| `sql/actualizacion_02_imagenes.sql` | Actualización sin borrar datos: fotos de productos (columna, función y bucket de Storage). |
| `sql/actualizacion_03_roles.sql` | Actualización sin borrar datos: roles de usuario y permisos. |
| `sql/actualizacion_04_tablero.sql` | Actualización sin borrar datos: el tablero solo lo ve el Administrador. |
| `tests/pruebas.sql` | 49 pruebas automáticas de reglas, seguridad, roles y reportes (opcional). |

## Instalación (5 minutos)

1. Crea un proyecto gratis en https://supabase.com.
2. Abre **SQL Editor → New query**, pega todo `sql/lotesmart_supabase.sql` y pulsa **Run**.
   Se puede volver a ejecutar cuando quieras: borra y recrea solo las tablas de LoteSmart con los datos de prueba.
3. En **Project Settings → API** copia la **Project URL** y la clave **anon public**.
4. Crea los usuarios (elige una opción):
   - **Desde Supabase:** Authentication → Users → **Add user → Create new user**, con correo y contraseña y marcando *Auto Confirm User*.
   - **Desde la app:** pestaña **Crear cuenta**. Por defecto Supabase manda un correo de confirmación; para la demo del hackathon puedes desactivarlo en Authentication → Sign In / Providers → Email → *Confirm email*.
   - Si publicas la app en internet, pon su dirección en Authentication → URL Configuration → *Site URL*, para que los enlaces de confirmación y de "olvidé mi contraseña" regresen a ella.
5. Abre `index.html` en el navegador (doble clic), pega la URL y la clave, pulsa **Conectar** e inicia sesión.

Para publicarla en internet súbela a Netlify Drop, Vercel o GitHub Pages. Si quieres que abra ya conectada, escribe la URL y la anon key en `CONFIG`, al inicio del `<script>` de `index.html`.

## Qué incluye la app

| Módulo | Altas | Bajas | Modificaciones | Listado y consulta |
|---|---|---|---|---|
| Productos | Nuevo producto | Baja lógica, reactivar, eliminar si no tiene lotes | Editar todos los campos | Buscar por SKU o nombre, filtro activos / baja |
| Proveedores | Nuevo proveedor (RFC validado) | Baja lógica, reactivar, eliminar si no entregó lotes | Editar | Buscar por RFC o razón social |
| Clientes | Nuevo cliente | Baja lógica, reactivar, eliminar si no tiene ventas | Editar | Buscar por nombre o RFC |
| Lotes | Entrada de mercancía | Bloquear con motivo, eliminar captura errónea | Código y caducidad siempre; cantidad, costo y producto solo sin movimientos | Buscar por lote, producto o proveedor; semáforo; "vence en N días" |
| Ventas | Carrito con "Simular FEFO" | Cancelar con motivo (devuelve a cada lote) | No se editan (regla del documento) | Folio, cliente, rango de fechas, estado |

Además: tablero de caducidad (valor en riesgo, no vendible, semáforo, alerta de reorden), mermas y ajustes con motivo, trazabilidad por lote y auditoría.

### Fotos de productos
Cada producto puede llevar una foto (JPG, PNG o WebP). La app la reduce sola a 800 px antes de subirla a Supabase Storage (bucket público `productos`, máximo 2 MB). Se ve en el catálogo, en el detalle del producto y en el carrito de ventas. Solo usuarios con sesión pueden subir o quitar fotos.

### Roles de usuario
Cada cuenta tiene un rol. La primera cuenta de la instalación queda como **Administrador**; las demás entran como **Consulta** hasta que un administrador les asigna otro rol en **Usuarios y permisos**.

| Permiso | Administrador | Almacén | Vendedor | Consulta |
|---|:-:|:-:|:-:|:-:|
| Tablero de caducidad y valor en riesgo | ✓ | | | |
| Productos y proveedores (alta, cambios, baja) | ✓ | ✓ | | |
| Clientes (alta, cambios, baja) | ✓ | | ✓ | |
| Entradas de lotes, correcciones y bloqueos | ✓ | ✓ | | |
| Mermas y ajustes | ✓ | ✓ | | |
| Registrar ventas | ✓ | | ✓ | |
| Cancelar ventas | ✓ | | | |
| Eliminar registros definitivamente | ✓ | | | |
| Reportes | ✓ | ✓ | ✓ | ✓ |
| Auditoría | ✓ | | | |
| Usuarios y permisos | ✓ | | | |

Todos pueden ver los catálogos, los lotes, las ventas y la trazabilidad. Quien no tiene el tablero entra directo a su primera pantalla (por ejemplo, el Vendedor a Ventas). Los permisos de cada rol se cambian con casillas en la misma pantalla. La base de datos valida el permiso en cada operación, así que no se puede saltar desde fuera de la app. Un usuario desactivado ya no ve ni registra nada, y siempre debe quedar al menos un administrador activo.

### Inicio de sesión
Con Supabase Auth (correo y contraseña): iniciar sesión, crear cuenta, recuperar contraseña y cerrar sesión. La sesión se renueva sola mientras la app está abierta. Cada venta, merma y cambio queda firmado con el nombre del usuario que inició sesión; la firma la pone la base de datos a partir del token, así nadie puede firmar como otra persona.

### Reportes
Ocho reportes con periodo (hoy, 7 días, este mes, mes anterior, este año o fechas libres), totales, gráfica y botones **Exportar CSV** (se abre en Excel) e **Imprimir / PDF**:

| Reporte | Qué muestra |
|---|---|
| Ventas del periodo | Cada venta con total, costo y margen, y gráfica de importe por día |
| Ventas por producto | Unidades, importe, costo, margen y % de margen por producto |
| Ventas por cliente | Ventas, importe, margen y última compra de cada cliente |
| Inventario valorizado | Existencia vigente, vendible y no vendible, y su valor a costo |
| Lotes por caducar | Lotes que vencen en N días, con su valor a costo |
| Mermas y ajustes | Pérdidas y correcciones valuadas a costo, con motivo y usuario |
| Entradas por proveedor | Lotes, unidades y costo recibido por proveedor |
| Kardex de producto | Entradas y salidas con saldo acumulado |

Los cálculos viven en funciones SQL (`rpt_*`), así que los números del reporte, del tablero y de los listados siempre coinciden.

## Base de datos normalizada (3FN)

```
unidad_medida 1──N producto 1──N lote N──1 proveedor
                                  │
cliente 1──N venta 1──N movimiento N──1 lote
auditoria (bitácora, se llena sola)
```

Cambios respecto al modelo MySQL para normalizar:
- **cliente** es una tabla propia. Antes era texto libre en la venta, y el mismo cliente podía quedar escrito de varias formas.
- **unidad_medida** es un catálogo. Antes era texto libre en el producto.
- **venta.total** ya no se guarda: se calcula en `v_venta_resumen` a partir de los movimientos, así nunca puede descuadrar.
- `lote.cantidad_disponible` es la única redundancia, y es controlada: solo la cambia un trigger a partir de los movimientos.

Las 17 reglas de negocio del documento viven en la base de datos (triggers, CHECK, UNIQUE, FOR UPDATE). Valen aunque alguien escriba SQL directo en Supabase.

## Seguridad

- Sin sesión iniciada no se puede ver ni modificar nada: el rol `anon` no tiene permisos.
- Con sesión (rol `authenticated`) se puede leer; RLS está activado en todas las tablas.
- Todas las escrituras pasan por funciones (`producto_guardar`, `venta_registrar`, etc.). Cada una es una transacción completa y queda firmada con el usuario de la sesión.
- Cada operación revisa el rol del usuario (ver **Roles de usuario**). Las tablas `rol`, `permiso`, `rol_permiso` y `usuario` guardan quién puede hacer qué.

## Caducados automáticos

El tablero ejecuta `marcar_caducados()` cada vez que se abre. Si quieres que corra solo cada noche, activa `pg_cron` en Supabase y ejecuta la línea comentada al final del script.

## Pruebas

En el SQL Editor, después de instalar, ejecuta `tests/pruebas.sql`. Debe terminar con **49 de 49 aprobadas**. Al final vuelve a ejecutar el script principal para dejar los datos de prueba limpios.
