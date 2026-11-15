--- Lo que puede costar el intercambio de dormir.
--
-- Al dormir la pantalla espera: el intercambio tiene que terminar en segundos
-- aunque la cola traiga cientos de eventos o el servidor tarde. Lo que no entra
-- en este presupuesto no se pierde: queda en el outbox y sale con el proximo
-- drenaje en segundo plano (lotes de `Queue.DEFAULT_MAX_EVENTS`).
--
-- Sin `require` de KOReader: se carga en las pruebas sin dobles.

local SleepBudget = {}

-- Eventos y bytes de UN lote al dormir.
SleepBudget.MAX_EVENTS = 40
SleepBudget.MAX_BYTES = 96 * 1024
-- Consultas de la ultima lectura que se permiten al dormir.
SleepBudget.FOCUS_CHECKS = 1
-- Tope de reloj de todo el intercambio de dormir.
SleepBudget.DEADLINE_SECONDS = 8
-- Una segunda instancia que duerme dentro de esta ventana no repite el intercambio.
SleepBudget.REPEAT_GUARD_SECONDS = 10
-- Lo que sale primero: la posicion y la sesion nunca esperan detras de subrayados.
SleepBudget.PRIORITY = { "progress.changed", "session.ended" }

local SLEEP_BLOCK_TIMEOUT = 4
local SLEEP_TOTAL_TIMEOUT = 8

--- Plazos de red para el modo `quick == "sleep"`. Cualquier otro valor devuelve
-- nil y quien llama sigue con su regla de siempre.
function SleepBudget.timeouts(quick)
    if quick == "sleep" then return SLEEP_BLOCK_TIMEOUT, SLEEP_TOTAL_TIMEOUT end
    return nil
end

return SleepBudget
