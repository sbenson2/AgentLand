package host

import (
	"archive/tar"
	"archive/zip"
	"compress/bzip2"
	"compress/gzip"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"runtime"
	"strings"
)

// Unpacking an agent's archive (docs/HOST-API.md "Installs, updates and
// uninstalls"). Everything is written through an os.Root on a fresh folder,
// so no path can leave it; nothing is written through a symbolic link; and
// once all entries are out, every link is resolved against what the archive
// made and must stay inside, then resolved again on disk through the root,
// as the system resolves it. Absolute paths, "..", devices and pipes are
// refused, and the entries and bytes are bounded.

type agentUnpackLimits struct {
	entries int
	bytes   int64
}

var defaultAgentUnpackLimits = agentUnpackLimits{entries: 100_000, bytes: 4 << 30}

var errAgentArchive = errors.New("the archive is not safe to unpack")

func agentArchiveError(format string, args ...any) error {
	return fmt.Errorf("%w: %s", errAgentArchive, fmt.Sprintf(format, args...))
}

// agentUnpacker writes one archive's entries into dest.
type agentUnpacker struct {
	root    *os.Root
	limits  agentUnpackLimits
	entries int
	written int64
	// links maps each symbolic link made (a clean, slash-separated path) to
	// its target.
	links map[string]string
}

// agentNamesFoldCase: macOS and Windows look names up without case by
// default, so the links made are known by their names in lower case there.
// The check on disk (checkLinksOnDisk) covers what this misses, such as
// another Unicode form of a name.
var agentNamesFoldCase = runtime.GOOS == "darwin" || runtime.GOOS == "windows"

// linkKey is the name a link is known by in u.links.
func linkKey(name string) string {
	if agentNamesFoldCase {
		return strings.ToLower(name)
	}
	return name
}

// unpackAgentArchive unpacks archivePath (zip, tar.gz or tar.bz2) into the
// empty folder dest.
func unpackAgentArchive(archivePath, format, dest string, limits agentUnpackLimits) error {
	root, err := os.OpenRoot(dest)
	if err != nil {
		return err
	}
	defer root.Close()
	u := &agentUnpacker{root: root, limits: limits, links: map[string]string{}}
	switch format {
	case "zip":
		err = u.zip(archivePath)
	case "tar.gz", "tar.bz2":
		file, openErr := os.Open(archivePath)
		if openErr != nil {
			return openErr
		}
		defer file.Close()
		var reader io.Reader = file
		if format == "tar.gz" {
			gz, gzErr := gzip.NewReader(file)
			if gzErr != nil {
				return agentArchiveError("not a gzip stream")
			}
			defer gz.Close()
			reader = gz
		} else {
			reader = bzip2.NewReader(file)
		}
		err = u.tar(reader)
	default:
		return agentArchiveError("unknown format %q", format)
	}
	if err != nil {
		return err
	}
	if err := u.checkLinks(); err != nil {
		return err
	}
	return u.checkLinksOnDisk()
}

// entryName checks an entry's name and returns it clean and slash-separated;
// "" is the folder itself.
func agentEntryName(name string) (string, error) {
	if name == "" || strings.ContainsAny(name, "\\\x00") || strings.HasPrefix(name, "/") || filepath.IsAbs(name) {
		return "", agentArchiveError("entry name %q", clipEntryName(name))
	}
	for _, component := range strings.Split(name, "/") {
		if component == ".." {
			return "", agentArchiveError("entry %q leaves the folder", clipEntryName(name))
		}
	}
	cleaned := path.Clean(name)
	if cleaned == "." {
		return "", nil
	}
	return cleaned, nil
}

func clipEntryName(name string) string {
	clipped, _ := clipText(name, 120)
	return clipped
}

// count admits one more entry.
func (u *agentUnpacker) count() error {
	u.entries++
	if u.entries > u.limits.entries {
		return agentArchiveError("more than %d entries", u.limits.entries)
	}
	return nil
}

// realParent refuses a path whose folders pass through a link the archive
// made: nothing is written through a link.
func (u *agentUnpacker) realParent(name string) error {
	parent := path.Dir(name)
	for parent != "." && parent != "/" {
		if _, linked := u.links[linkKey(parent)]; linked {
			return agentArchiveError("entry %q is inside a linked folder", clipEntryName(name))
		}
		parent = path.Dir(parent)
	}
	return nil
}

func (u *agentUnpacker) makeParents(name string) error {
	parent := path.Dir(name)
	if parent == "." {
		return nil
	}
	return u.root.MkdirAll(filepath.FromSlash(parent), 0o700)
}

// clear removes a file or link already at name (a later entry of the same
// name replaces it); a folder there is an error.
func (u *agentUnpacker) clear(name string) error {
	info, err := u.root.Lstat(filepath.FromSlash(name))
	if errors.Is(err, fs.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	if info.IsDir() {
		return agentArchiveError("entry %q replaces a folder", clipEntryName(name))
	}
	delete(u.links, linkKey(name))
	return u.root.Remove(filepath.FromSlash(name))
}

func (u *agentUnpacker) dir(name string) error {
	if name == "" {
		return nil
	}
	if err := u.realParent(name + "/x"); err != nil {
		return err
	}
	if _, linked := u.links[linkKey(name)]; linked {
		return agentArchiveError("folder %q is a link", clipEntryName(name))
	}
	return u.root.MkdirAll(filepath.FromSlash(name), 0o700)
}

func (u *agentUnpacker) file(name string, executable bool, content io.Reader) error {
	if name == "" {
		return agentArchiveError("a file entry names the folder itself")
	}
	if err := u.realParent(name); err != nil {
		return err
	}
	if err := u.makeParents(name); err != nil {
		return err
	}
	if err := u.clear(name); err != nil {
		return err
	}
	mode := os.FileMode(0o600)
	if executable {
		mode = 0o700
	}
	file, err := u.root.OpenFile(filepath.FromSlash(name), os.O_CREATE|os.O_EXCL|os.O_WRONLY, mode)
	if err != nil {
		return err
	}
	left := u.limits.bytes - u.written
	written, copyErr := io.Copy(file, io.LimitReader(content, left+1))
	closeErr := file.Close()
	u.written += written
	if copyErr != nil {
		return copyErr
	}
	if closeErr != nil {
		return closeErr
	}
	if u.written > u.limits.bytes {
		return agentArchiveError("more than %d bytes unpacked", u.limits.bytes)
	}
	// The umask may have taken bits away; the mode is exactly 0600 or 0700.
	return u.root.Chmod(filepath.FromSlash(name), mode)
}

func (u *agentUnpacker) symlink(name, target string) error {
	if name == "" {
		return agentArchiveError("a link entry names the folder itself")
	}
	if target == "" || strings.ContainsRune(target, 0) || strings.HasPrefix(target, "/") || filepath.IsAbs(target) || strings.Contains(target, "\\") {
		return agentArchiveError("link %q points to an absolute or empty path", clipEntryName(name))
	}
	if err := u.realParent(name); err != nil {
		return err
	}
	if err := u.makeParents(name); err != nil {
		return err
	}
	if err := u.clear(name); err != nil {
		return err
	}
	// A first check now; the tree as a whole is checked again at the end.
	if _, ok := u.resolve(joinUnclean(path.Dir(name), target), 0); !ok {
		return agentArchiveError("link %q leaves the folder", clipEntryName(name))
	}
	if err := u.root.Symlink(filepath.FromSlash(target), filepath.FromSlash(name)); err != nil {
		return err
	}
	u.links[linkKey(name)] = target
	return nil
}

func (u *agentUnpacker) hardlink(name, target string) error {
	cleanTarget, err := agentEntryName(target)
	if err != nil || cleanTarget == "" || name == "" {
		return agentArchiveError("hard link %q", clipEntryName(name))
	}
	if err := u.realParent(name); err != nil {
		return err
	}
	if err := u.realParent(cleanTarget); err != nil {
		return err
	}
	info, err := u.root.Lstat(filepath.FromSlash(cleanTarget))
	if err != nil || !info.Mode().IsRegular() {
		return agentArchiveError("hard link %q names no earlier file", clipEntryName(name))
	}
	if err := u.makeParents(name); err != nil {
		return err
	}
	if err := u.clear(name); err != nil {
		return err
	}
	return u.root.Link(filepath.FromSlash(cleanTarget), filepath.FromSlash(name))
}

// joinUnclean joins a folder and a link target without cleaning: ".." after a
// link must go up from where the link leads, as the system resolves it, not
// cancel the link's name.
func joinUnclean(folder, target string) string {
	if folder == "." || folder == "" {
		return target
	}
	return folder + "/" + target
}

// resolve follows the archive's links along p (slash-separated, relative to
// the folder, never cleaned beforehand) and returns where it leads, or false
// when it leaves the folder or loops.
func (u *agentUnpacker) resolve(p string, depth int) (string, bool) {
	if depth > 40 {
		return "", false
	}
	var current []string
	for _, component := range strings.Split(p, "/") {
		switch component {
		case "", ".":
			continue
		case "..":
			if len(current) == 0 {
				return "", false
			}
			current = current[:len(current)-1]
			continue
		}
		current = append(current, component)
		joined := strings.Join(current, "/")
		if target, linked := u.links[linkKey(joined)]; linked {
			base := strings.Join(current[:len(current)-1], "/")
			resolved, ok := u.resolve(joinUnclean(base, target), depth+1)
			if !ok {
				return "", false
			}
			current = nil
			if resolved != "" {
				current = strings.Split(resolved, "/")
			}
		}
	}
	return strings.Join(current, "/"), true
}

// checkLinks resolves every link against the finished tree.
func (u *agentUnpacker) checkLinks() error {
	for name, target := range u.links {
		if _, ok := u.resolve(joinUnclean(path.Dir(name), target), 0); !ok {
			return agentArchiveError("link %q leaves the folder", clipEntryName(name))
		}
	}
	return nil
}

// checkLinksOnDisk resolves every link in the finished tree as the system
// does, through the root, which follows a link only while it stays inside:
// a link that leaves the folder or loops (any error but "does not exist")
// refuses the archive. The checks by name above cannot see every name the
// file system takes for another (case, Unicode forms).
func (u *agentUnpacker) checkLinksOnDisk() error {
	return fs.WalkDir(u.root.FS(), ".", func(name string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if entry.Type()&fs.ModeSymlink == 0 {
			return nil
		}
		if _, err := u.root.Stat(filepath.FromSlash(name)); err != nil && !errors.Is(err, fs.ErrNotExist) {
			return agentArchiveError("link %q leaves the folder or loops", clipEntryName(name))
		}
		return nil
	})
}

func (u *agentUnpacker) zip(archivePath string) error {
	reader, err := zip.OpenReader(archivePath)
	if err != nil {
		return agentArchiveError("not a zip archive")
	}
	defer reader.Close()
	for _, entry := range reader.File {
		if err := u.count(); err != nil {
			return err
		}
		name, err := agentEntryName(entry.Name)
		if err != nil {
			return err
		}
		mode := entry.Mode()
		switch {
		case mode.IsDir():
			if err := u.dir(name); err != nil {
				return err
			}
		case mode&fs.ModeSymlink != 0:
			content, err := entry.Open()
			if err != nil {
				return agentArchiveError("link %q cannot be read", clipEntryName(name))
			}
			target, readErr := io.ReadAll(io.LimitReader(content, 4097))
			content.Close()
			if readErr != nil || len(target) > 4096 {
				return agentArchiveError("link %q", clipEntryName(name))
			}
			if err := u.symlink(name, string(target)); err != nil {
				return err
			}
		case mode.IsRegular():
			content, err := entry.Open()
			if err != nil {
				return agentArchiveError("entry %q cannot be read", clipEntryName(name))
			}
			err = u.file(name, mode.Perm()&0o111 != 0, content)
			content.Close()
			if err != nil {
				return err
			}
		default:
			return agentArchiveError("entry %q is not a file, folder or link", clipEntryName(name))
		}
	}
	return nil
}

func (u *agentUnpacker) tar(stream io.Reader) error {
	reader := tar.NewReader(stream)
	for {
		header, err := reader.Next()
		if errors.Is(err, io.EOF) {
			return nil
		}
		if err != nil {
			return agentArchiveError("the tar stream is damaged")
		}
		if header.Typeflag == tar.TypeXGlobalHeader {
			continue
		}
		if err := u.count(); err != nil {
			return err
		}
		name, err := agentEntryName(header.Name)
		if err != nil {
			return err
		}
		switch header.Typeflag {
		case tar.TypeDir:
			err = u.dir(name)
		case tar.TypeReg, tar.TypeRegA:
			err = u.file(name, header.Mode&0o111 != 0, reader)
		case tar.TypeSymlink:
			err = u.symlink(name, header.Linkname)
		case tar.TypeLink:
			err = u.hardlink(name, header.Linkname)
		default:
			err = agentArchiveError("entry %q is not a file, folder or link", clipEntryName(name))
		}
		if err != nil {
			return err
		}
	}
}

// resolveAgentCmd finds cmd inside dest: it must lead, links followed, to a
// regular file there, which is made executable (0700) when the archive kept
// no mode for it (a zip made without Unix modes). It returns the command's
// path.
func resolveAgentCmd(dest, cmd string) (string, error) {
	root, err := os.OpenRoot(dest)
	if err != nil {
		return "", err
	}
	defer root.Close()
	// Stat follows links only while they stay inside the root.
	info, err := root.Stat(filepath.FromSlash(cmd))
	if err != nil {
		return "", fmt.Errorf("the command %q is not in the download", cmd)
	}
	if !info.Mode().IsRegular() {
		return "", fmt.Errorf("the command %q is not a file", cmd)
	}
	if info.Mode().Perm()&0o100 == 0 {
		if err := root.Chmod(filepath.FromSlash(cmd), 0o700); err != nil {
			return "", err
		}
	}
	return filepath.Join(dest, filepath.FromSlash(cmd)), nil
}
