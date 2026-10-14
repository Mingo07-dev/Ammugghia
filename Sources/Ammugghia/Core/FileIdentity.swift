import Foundation
import Darwin

/// Identità fisica di un percorso: dispositivo e inode, più il tipo.
///
/// Viene catturata quando lo scanner crea l'elemento e ricontrollata subito
/// prima di eliminare. Fra l'analisi e la conferma possono passare minuti: se
/// nel frattempo al posto della cartella analizzata ne compare un'altra con lo
/// stesso nome, o un collegamento, o un volume montato, l'eliminazione va
/// rifiutata. Il nome uguale non basta a dire che è la stessa cosa.
struct FileIdentity: Hashable, Codable {
    let device: UInt64
    let inode: UInt64
    let isDirectory: Bool
    let isSymlink: Bool

    /// `lstat`, mai `stat`: un collegamento simbolico va descritto per quello
    /// che è, non per la destinazione a cui punta.
    static func of(_ path: String) -> FileIdentity? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        let type = info.st_mode & S_IFMT
        return FileIdentity(device: UInt64(info.st_dev),
                            inode: UInt64(info.st_ino),
                            isDirectory: type == S_IFDIR,
                            isSymlink: type == S_IFLNK)
    }

    /// Segnaposto di iCloud o di un File Provider: il contenuto non è sul
    /// disco. Leggerlo ne provocherebbe lo scaricamento, e la dimensione
    /// dichiarata non corrisponde a spazio occupato.
    static func isDataless(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return info.st_flags & UInt32(SF_DATALESS) != 0
    }
}
