import Foundation
import Darwin

/// Una voce di cartella letta con `getattrlistbulk`.
struct BulkEntry {
    let name: String
    let isDirectory: Bool
    let isRegularFile: Bool
    let device: UInt64
    let inode: UInt64
    let modified: Int64
    let flags: UInt32
    let linkCount: UInt32
    /// Dimensione logica (i byte del contenuto), diversa dallo spazio
    /// allocato: serve a confrontare il contenuto di due file.
    let logicalSize: Int64
    let allocated: Int64

    /// Segnaposto di iCloud o di un File Provider: il contenuto non è qui.
    var isDataless: Bool { flags & UInt32(SF_DATALESS) != 0 }

    /// Spazio attribuito a questa voce. Un file con più collegamenti fisici
    /// conta per la sua quota: sommando tutte le copie si ottiene lo spazio
    /// reale, qualunque sia l'ordine in cui vengono viste. Contare la prima
    /// copia per intero, come fa `du`, darebbe risultati diversi fra una
    /// scansione completa e un aggiornamento parziale.
    var share: Int64 {
        guard isRegularFile, !isDataless else { return 0 }
        return linkCount > 1 ? allocated / Int64(linkCount) : allocated
    }
}

/// Lettura delle cartelle con `getattrlistbulk`: una chiamata restituisce
/// nome, tipo e dimensione di molte voci insieme, invece di una `stat` per
/// file. Su alberi grandi è la differenza fra minuti e secondi.
///
/// Non segue i collegamenti simbolici e non apre nulla oltre la cartella.
enum BulkEnumerator {

    // Valori di <sys/attr.h>, ridichiarati come UInt32: importati da C hanno
    // tipi diversi fra loro e il più alto non sta in un Int32.
    private static let cmnName: UInt32 = 0x0000_0001
    private static let cmnDevID: UInt32 = 0x0000_0002
    private static let cmnObjType: UInt32 = 0x0000_0008
    private static let cmnModTime: UInt32 = 0x0000_0400
    private static let cmnFlags: UInt32 = 0x0004_0000
    private static let cmnFileID: UInt32 = 0x0200_0000
    private static let cmnError: UInt32 = 0x2000_0000
    private static let cmnReturnedAttrs: UInt32 = 0x8000_0000
    private static let fileLinkCount: UInt32 = 0x0000_0001
    private static let fileTotalSize: UInt32 = 0x0000_0002
    private static let fileAllocSize: UInt32 = 0x0000_0004

    private static let typeRegular: UInt32 = 1   // VREG
    private static let typeDirectory: UInt32 = 2 // VDIR

    /// Le voci della cartella, oppure `nil` se non è leggibile (permessi,
    /// protezione della privacy di macOS) o se la lettura si interrompe: una
    /// lettura parziale non deve mai sembrare completa.
    static func entries(of path: String) -> [BulkEntry]? {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var request = attrlist()
        request.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        request.commonattr = cmnReturnedAttrs | cmnError | cmnName | cmnDevID | cmnObjType
            | cmnModTime | cmnFlags | cmnFileID
        request.fileattr = fileLinkCount | fileTotalSize | fileAllocSize

        let capacity = 256 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
        defer { buffer.deallocate() }

        var result: [BulkEntry] = []
        while true {
            let count = withUnsafeMutablePointer(to: &request) {
                getattrlistbulk(fd, UnsafeMutableRawPointer($0), buffer, capacity, 0)
            }
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if count == 0 { break }

            var cursor = buffer
            for _ in 0..<Int(count) {
                let length = Int(cursor.loadUnaligned(as: UInt32.self))
                defer { cursor += length }
                if let entry = parse(cursor + 4) { result.append(entry) }
            }
        }
        return result
    }

    /// Gli attributi sono impacchettati nell'ordine dei bit, allineati a 4
    /// byte: i valori a 8 byte vanno letti senza assumere allineamento.
    private static func parse(_ start: UnsafeMutableRawPointer) -> BulkEntry? {
        var field = start
        let returned = field.loadUnaligned(as: attribute_set_t.self)
        field += MemoryLayout<attribute_set_t>.size
        let common = returned.commonattr
        let file = returned.fileattr

        if common & cmnError != 0 {
            let error = field.loadUnaligned(as: UInt32.self)
            field += 4
            if error != 0 { return nil }
        }
        var name = ""
        if common & cmnName != 0 {
            let offset = Int(field.loadUnaligned(as: Int32.self))
            name = String(cString: (field + offset).assumingMemoryBound(to: CChar.self))
            field += MemoryLayout<attrreference_t>.size
        }
        var device: UInt64 = 0
        if common & cmnDevID != 0 {
            device = UInt64(UInt32(bitPattern: field.loadUnaligned(as: Int32.self)))
            field += 4
        }
        var type: UInt32 = 0
        if common & cmnObjType != 0 {
            type = field.loadUnaligned(as: UInt32.self)
            field += 4
        }
        var modified: Int64 = 0
        if common & cmnModTime != 0 {
            modified = Int64(field.loadUnaligned(as: Int.self))
            field += MemoryLayout<timespec>.size
        }
        var flags: UInt32 = 0
        if common & cmnFlags != 0 {
            flags = field.loadUnaligned(as: UInt32.self)
            field += 4
        }
        var inode: UInt64 = 0
        if common & cmnFileID != 0 {
            inode = field.loadUnaligned(as: UInt64.self)
            field += 8
        }
        var links: UInt32 = 1
        if file & fileLinkCount != 0 {
            links = field.loadUnaligned(as: UInt32.self)
            field += 4
        }
        var logical: Int64 = 0
        if file & fileTotalSize != 0 {
            logical = field.loadUnaligned(as: Int64.self)
            field += 8
        }
        var allocated: Int64 = 0
        if file & fileAllocSize != 0 {
            allocated = field.loadUnaligned(as: Int64.self)
            field += 8
        }
        guard !name.isEmpty, name != ".", name != ".." else { return nil }
        return BulkEntry(name: name, isDirectory: type == typeDirectory,
                         isRegularFile: type == typeRegular, device: device, inode: inode,
                         modified: modified, flags: flags, linkCount: max(1, links),
                         logicalSize: logical, allocated: allocated)
    }

    /// Dispositivo di un percorso, senza seguire collegamenti.
    static func device(of path: String) -> UInt64? {
        FileIdentity.of(path)?.device
    }
}
