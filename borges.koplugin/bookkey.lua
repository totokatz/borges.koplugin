--- La clave local de un libro.
--
-- El `partial_md5_checksum` de KOReader son doce muestras de 1 KB del archivo:
-- dos libros distintos pueden compartirlo (medido en produccion: dos tomos de
-- una coleccion, varios fics del mismo sitio). Lo que el plugin guardaba por
-- hash —lo ya sincronizado de un libro, las retenciones de posicion, la marca
-- de la foto historica— mezclaba esos libros: abrir uno daba por borrados los
-- subrayados del otro.
--
-- La clave es el hash mas una huella del nombre del archivo (sin carpeta) y
-- del titulo:
--
--   <hash en minusculas>-<16 primeros hex de md5(nombre .. "\n" .. titulo)>
--
-- Mover el archivo de carpeta no la cambia; renombrarlo o editar el titulo si,
-- y para eso esta `migrate`, que muda lo guardado sin re-emitir nada. Cuando
-- falta el titulo, KOReader muestra el nombre del archivo, y el descriptor de
-- anotaciones hace lo mismo: un titulo vacio o igual al nombre cuenta como
-- vacio, asi las dos formas dan la misma clave.
--
-- Es local: no viaja al servidor. 49 caracteres de [%w%-], que caben como
-- nombre del archivo del libro en la cola sin rehash.

local md5 = require("ffi/sha2").md5

local BookKey = {}

local UUID_RE = "^%x%x%x%x%x%x%x%x%-%x%x%x%x%-[1-8]%x%x%x%-[89aAbB]%x%x%x%-"
    .. string.rep("%x", 12) .. "$"

local function clean(value)
    if type(value) ~= "string" then return "" end
    return (value:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""):lower())
end

local function baseName(file)
    if type(file) ~= "string" then return "" end
    return file:match("([^/\\]+)$") or file
end

--- @return string|nil la clave, o nil sin hash
function BookKey.fromParts(book_hash, file, title)
    if type(book_hash) ~= "string" or book_hash == "" then return nil end
    local name = clean(baseName(file))
    local t = clean(title)
    if t == name then t = "" end
    return book_hash:lower() .. "-" .. md5(name .. "\n" .. t):lower():sub(1, 16)
end

--- La clave del libro abierto. Se calcula una vez por apertura, nunca al
-- pasar pagina.
function BookKey.forDocument(ui)
    if type(ui) ~= "table" then return nil end
    local hash
    if ui.doc_settings and ui.doc_settings.readSetting then
        local ok, value = pcall(ui.doc_settings.readSetting, ui.doc_settings, "partial_md5_checksum")
        if ok and value then hash = tostring(value) end
    end
    if not hash then return nil end
    local document = ui.document
    local file = document and document.file
    local title
    if document and document.getProps then
        local ok, props = pcall(document.getProps, document)
        if ok and type(props) == "table" then title = props.title end
    end
    return BookKey.fromParts(hash, file, title)
end

--- Mudar a `key` lo ya sincronizado de este libro, guardado por hash (o por una
-- clave anterior: un archivo renombrado). Solo se adopta lo que el sidecar del
-- libro abierto prueba que es suyo: con dos libros del mismo hash, cada uno se
-- lleva lo propio y nada del otro.
--
-- `derive(item)` da el id que la formula vieja le hubiera dado a una anotacion
-- que todavia no lo tiene guardado (lo inyecta quien llama, desde
-- AnnotationAdapter). Una clave que ya tiene estado no se toca nunca.
-- @return number entradas adoptadas
function BookKey.migrate(queue, key, book_hash, annotations, derive)
    if type(key) ~= "string" or key == "" or type(book_hash) ~= "string" or book_hash == "" then
        return 0
    end
    if queue:hasAnnotationState(key) then return 0 end
    local ids = {}
    for _, item in ipairs(type(annotations) == "table" and annotations or {}) do
        if type(item) == "table" then
            local id = item.toto_sync_id
            if type(id) == "string" and id:match(UUID_RE) then
                ids[id:lower()] = true
            elseif derive then
                local ok, derived = pcall(derive, item)
                if ok and type(derived) == "string" and derived ~= "" then ids[derived:lower()] = true end
            end
        end
    end
    local adopted = queue:adoptAnnotationState(key, queue:annotationKeysForHash(book_hash), ids, book_hash)
    queue:rememberBookKey(book_hash, key)
    return adopted
end

return BookKey
