include "typed_fs.dfy"
include "mem_dirent.dfy"
include "nfs.s.dfy"

module DirFs
{
  import opened Std
  import opened Machine
  import opened ByteSlice
  import opened Fs
  import opened FsKinds
  import opened JrnlTypes
  import opened JrnlSpec
  import opened Alloc

  import opened DirEntries
  import opened MemDirEntries
  import opened TypedFs

  import opened Nfs

  import C = Collections

  datatype File =
    | ByteFile(data: seq<byte>)
    | DirFile(dir: Directory)
  {
    static const empty := ByteFile([])
    static const emptyDir := DirFile(map[])
  }

  type FsData = map<Ino, seq<byte>>
  type Data = map<Ino, File>

  method HandleResult<T>(r: Result<T>, txn: Txn) returns (r':Result<T>)
    requires txn.Valid()
    ensures r.Err? ==> r'.Err?
  {
    if r.Err? {
      txn.Abort();
      return r;
    }
    var ok := txn.Commit();
    if !ok {
      return Err(ServerFault);
    }
    return r;
  }

  datatype Attributes = Attributes(is_dir: bool, size: uint64)

  class DirFilesys
  {
    // external abstract state
    //
    // domain consists of allocated inodes
    ghost var data: map<Ino, File>

    // internal state, tracking exactly how directories are encoded
    // domain is just the inodes that are allocated directories
    ghost var dirents: map<Ino, Dirents>
    const fs: TypedFilesys

    static const rootIno: Ino := 1 as Ino;

    ghost const Repr: set<object> := {this} + fs.Repr

    predicate is_invalid(ino: Ino) reads this
    { ino !in data && ino !in dirents }

    predicate is_file(ino: Ino) reads this
    { ino in data && ino !in dirents && data[ino].ByteFile? }

    predicate is_dir(ino: Ino) reads this
    { ino in data && ino in dirents && data[ino].DirFile? }

    predicate {:opaque} is_of_type(ino: Ino, t: Inode.InodeType)
      reads this
    {
      && (t.InvalidType? ==> is_invalid(ino))
      && (t.FileType? ==> is_file(ino))
      && (t.DirType? ==> is_dir(ino))
    }

    lemma mk_dir_type(ino: Ino)
      requires fs.Valid()
      requires is_dir(ino)
      requires fs.types[ino] == Inode.DirType
      ensures is_of_type(ino, fs.types[ino])
    {
      reveal is_of_type();
    }

    lemma mk_file_type(ino: Ino)
      requires fs.Valid()
      requires is_file(ino)
      requires fs.types[ino] == Inode.FileType
      ensures is_of_type(ino, fs.types[ino])
    {
      reveal is_of_type();
    }

    lemma mk_invalid_type(ino: Ino)
      requires fs.Valid()
      requires is_invalid(ino)
      requires fs.types[ino] == Inode.InvalidType
      ensures is_of_type(ino, fs.types[ino])
    {
      reveal is_of_type();
    }

    predicate ValidTypes()
      reads this, fs
      requires fs.ValidDomains()
    {
      forall ino: Ino :: is_of_type(ino, fs.types[ino])
    }

    lemma invert_dir(ino: Ino)
      requires fs.ValidDomains()
      requires ValidTypes()
      requires is_dir(ino)
      ensures fs.types[ino] == Inode.DirType
    {
      reveal is_of_type();
      ghost var t := fs.types[ino];
      assert is_of_type(ino, t);
      if t == Inode.InvalidType {}
      else if t == Inode.FileType {}
      else if t == Inode.DirType {}
    }

    lemma invert_file(ino: Ino)
      requires fs.ValidDomains()
      requires ValidTypes()
      requires is_file(ino)
      ensures fs.types[ino] == Inode.FileType
    {
      reveal is_of_type();
      ghost var t := fs.types[ino];
      assert is_of_type(ino, t);
      if t == Inode.InvalidType {}
      else if t == Inode.FileType {}
      else if t == Inode.DirType {}
    }

    predicate {:opaque} ValidRoot()
      reads this
    {
      && is_dir(rootIno)
      && rootIno != 0
    }

    predicate Valid_dirent_at(ino: Ino, fsdata: FsData)
      reads this
      requires ino_dom(fsdata)
    {
      ino in dirents ==> fsdata[ino] == dirents[ino].enc()
    }

    predicate Valid_file_at(ino: Ino, fsdata: FsData)
      reads this
      requires ino_dom(fsdata)
    {
      is_file(ino) ==> this.data[ino] == ByteFile(fsdata[ino])
    }

    predicate Valid_dir_at(ino: Ino)
      reads this
    {
      is_dir(ino) ==> this.data[ino] == DirFile(dirents[ino].dir)
    }

    predicate Valid_invalid_at(ino: Ino, fsdata: FsData)
      requires ino_dom(fsdata)
      reads this
    {
      is_invalid(ino) ==> fsdata[ino] == []
    }

    predicate {:opaque} Valid_data_at(ino: Ino, fsdata: FsData)
      requires ino_dom(fsdata)
      reads this
    {
        && Valid_dirent_at(ino, fsdata)
        && Valid_file_at(ino, fsdata)
        && Valid_dir_at(ino)
        && Valid_invalid_at(ino, fsdata)
    }

    predicate ValidData()
      requires fs.ValidDomains()
      reads this, fs
    {
      forall ino: Ino :: Valid_data_at(ino, fs.data)
    }

    lemma get_data_at(ino: Ino)
      requires fs.ValidDomains() && ValidData()
      ensures Valid_dirent_at(ino, fs.data)
      ensures Valid_file_at(ino, fs.data)
      ensures Valid_dir_at(ino)
      ensures Valid_invalid_at(ino, fs.data)
    {
      reveal Valid_data_at();
      assert Valid_data_at(ino, fs.data);
    }

    lemma mk_data_at(ino: Ino)
      requires fs.ValidDomains()
      requires Valid_dirent_at(ino, fs.data)
      requires Valid_file_at(ino, fs.data)
      requires Valid_dir_at(ino)
      requires Valid_invalid_at(ino, fs.data)
      ensures Valid_data_at(ino, fs.data)
    {
      reveal Valid_data_at();
    }

    twostate lemma ValidData_change_one(ino: Ino)
      requires old(fs.ValidDomains()) && old(ValidData()) && old(ValidTypes())
      requires fs.ValidDomains()
      requires Valid_data_at(ino, fs.data)
      requires is_of_type(ino, fs.types[ino])
      requires (forall ino': Ino | ino' != ino ::
      && fs.data[ino'] == old(fs.data[ino'])
      && (ino' in dirents ==> ino' in old(dirents) && dirents[ino'] == old(dirents[ino']))
      && (ino' in data ==> ino' in old(data) && data[ino'] == old(data[ino']))
      && (ino' !in data ==> ino' !in old(data))
      && (ino' !in dirents ==> ino' !in old(dirents))
      && fs.types[ino'] == old(fs.types[ino']))
      ensures ValidData()
      ensures ValidTypes()
    {
      var ino0 := ino;
      assert ValidTypes() by {
        reveal is_of_type();
      }
      var fsdata0 := old(fs.data);
      var fsdata := fs.data;
      forall ino: Ino | ino != ino0
        ensures Valid_data_at(ino, fsdata)
      {
        reveal Valid_data_at();
        assert old(Valid_data_at(ino, fsdata0));
        assert ino in dirents ==> ino in old(dirents);
        assert is_file(ino) ==> old(is_file(ino));
      }
    }

    predicate ValidDirFs()
      requires fs.ValidDomains()
      reads this, fs
    {
      && ValidTypes()
      && ValidRoot()
      && ValidData()
    }

    predicate Valid()
      reads Repr
    {
      && fs.Valid()
      && ValidDirFs()
    }

    predicate ValidIno(ino: Ino, i: Inode.Inode)
      reads Repr
    {
      && fs.ValidIno(ino, i)
      && ValidDirFs()
    }

    constructor Init(fs: TypedFilesys)
      requires fs.Valid()
      requires fs.data == map ino: Ino {:trigger} :: if ino == rootIno then Dirents.zero.enc() else []
      requires fs.types == map ino: Ino {:trigger} :: if ino == rootIno then Inode.DirType else Inode.InvalidType
      ensures Valid()
      ensures this.rootIno == rootIno
      ensures data == map[rootIno := File.emptyDir]
    {
      this.fs := fs;
      var dirents0 : map<Ino, Dirents> := map[rootIno := Dirents.zero];
      this.dirents := dirents0;
      this.data := map[rootIno := File.emptyDir];
      new;
      Dirents.zero_dir();
      assert ValidData() by {
        reveal Valid_data_at();
      }
      assert ValidRoot() by { reveal ValidRoot(); }
      assert ValidTypes() by { reveal is_of_type(); }
    }

    static method createRootDir(fs: TypedFilesys, txn: Txn, ino: Ino) returns (ok: bool)
      modifies fs.Repr
      requires fs.Valid() ensures ok ==> fs.Valid()
      requires fs.has_jrnl(txn)
      requires fs.types[ino] == Inode.InvalidType
      requires fs.data[ino] == []
      ensures ok ==>
      && fs.data == old(fs.data[ino := Dirents.zero.enc()])
      && fs.types == old(fs.types[ino := Inode.DirType])
    {
      var i := fs.allocateAt(txn, ino, Inode.DirType);
      ok := writeEmptyDirToFs(fs, txn, ino, i);
    }

    static method New(d: Disk) returns (fs: Option<DirFilesys>)
      ensures fs.Some? ==> fresh(fs.x) && fs.x.Valid()
      ensures fs.Some? ==> fs.x.data == map[fs.x.rootIno := DirFile(map[])]
    {
      var fs_ := new TypedFilesys.Init(d);

      fs_.reveal_valids();
      var txn := fs_.fs.fs.fs.jrnl.Begin();
      var ok := createRootDir(fs_, txn, rootIno);
      if !ok {
        return None;
      }
      fs_.reveal_valids();
      ok := txn.Commit();
      if !ok {
        return None;
      }
      assert fs_.Valid();

      var dir_fs := new DirFilesys.Init(fs_);
      return Some(dir_fs);
    }

    method Begin() returns (txn: Txn)
      requires Valid()
      ensures fs.has_jrnl(txn)
    {
      fs.reveal_valids();
      txn := fs.fs.fs.fs.jrnl.Begin();
    }

    method readDirentsInode(txn: Txn, d_ino: Ino, i: Inode.Inode)
      returns (dents: MemDirents)
      requires ValidIno(d_ino, i)
      requires fs.has_jrnl(txn)
      requires is_dir(d_ino)
      ensures dents.val == dirents[d_ino]
      ensures fresh(dents.Repr)
      ensures dents.Valid()
    {
      assert Valid_dirent_at(d_ino, fs.data) by {
        get_data_at(d_ino);
      }
      assert |fs.data[d_ino]| == 4096 by {
        dirents[d_ino].enc_len();
      }
      var bs := fs.readUnsafe(txn, d_ino, i, 0, 4096);
      dents := new MemDirents(bs, dirents[d_ino]);
    }

    method readDirents(txn: Txn, d_ino: Ino)
      returns (r: Result<MemDirents>)
      modifies fs.fs.fs.fs
      requires Valid() ensures Valid()
      requires fs.has_jrnl(txn)
      ensures r.ErrBadHandle? ==> is_invalid(d_ino)
      ensures r.ErrNotDir? ==> is_file(d_ino)
      ensures r.Err? ==> r.err.BadHandle? || r.err.NotDir?
      ensures r.Ok? ==>
      && is_dir(d_ino)
      && r.v.Valid()
      && fresh(r.v.Repr)
      && r.v.val == dirents[d_ino]
    {
      var ok, i := fs.startInode(txn, d_ino);
      if !ok {
        assert is_invalid(d_ino) by { reveal is_of_type(); }
        return Err(BadHandle);
      }
      if i.meta.ty.FileType? {
        fs.finishInodeReadonly(d_ino, i);
        assert is_file(d_ino) by { reveal is_of_type(); }
        return Err(NotDir);
      }
      assert is_dir(d_ino) by { reveal is_of_type(); }
      var dents := readDirentsInode(txn, d_ino, i);
      fs.finishInodeReadonly(d_ino, i);
      assert ValidData();
      return Ok(dents);
    }

    static method writeDirentsToFs(fs: TypedFilesys, txn: Txn, d_ino: Ino, dents: MemDirents)
      returns (ok:bool)
      modifies fs.Repr
      requires fs.Valid() ensures ok ==> fs.Valid()
      requires dents.Valid()
      requires fs.has_jrnl(txn)
      requires |fs.data[d_ino]| == 4096
      ensures fs.types_unchanged()
      ensures ok ==> fs.data == old(fs.data[d_ino := dents.val.enc()])
      ensures dents.val == old(dents.val)
    {
      assert dents.Repr !! fs.Repr;
      var i;
      ok, i := fs.startInode(txn, d_ino);
      if !ok {
        return;
      }
      var bs := dents.encode();
      dents.val.enc_len();
      C.splice_all(fs.data[d_ino], bs.data);
      ok, i := fs.writeBlockFile(txn, d_ino, i, bs);
      if !ok {
        return;
      }
      fs.finishInode(txn, d_ino, i);
      assert fs.data[d_ino] == dents.val.enc();
    }

    method writeDirents(txn: Txn, d_ino: Ino, dents: MemDirents)
      returns (ok:bool)
      modifies Repr
      requires fs.has_jrnl(txn)
      requires Valid() ensures ok ==> Valid()
      requires dents.Valid()
      requires is_dir(d_ino)
      ensures ok ==>
           && dirents == old(dirents[d_ino := dents.val])
           && data == old(data[d_ino := DirFile(dents.dir())])
    {
      assert |fs.data[d_ino]| == 4096 by {
        get_data_at(d_ino);
        dirents[d_ino].enc_len();
      }
      assert fs.types[d_ino] == Inode.DirType by {
        invert_dir(d_ino);
      }
      ghost var dents_val := dents.val;
      ok := writeDirentsToFs(fs, txn, d_ino, dents);
      if !ok {
        return;
      }

      dirents := dirents[d_ino := dents_val];
      data := data[d_ino := DirFile(dents_val.dir)];

      assert is_dir(d_ino);
      assert is_of_type(d_ino, fs.types[d_ino]) by { reveal is_of_type(); }
      mk_data_at(d_ino);
      ValidData_change_one(d_ino);
      assert ValidRoot() by { reveal ValidRoot(); }
    }

    // private
    //
    // creates a file disconnected from the file system (which is perfectly
    // legal but useless for most clients)
    method allocFile(txn: Txn)
      returns (ok: bool, ino: Ino)
      modifies Repr
      requires Valid() ensures ok ==> Valid()
      requires fs.has_jrnl(txn)
      ensures dirents == old(dirents)
      ensures ok ==>
      && old(is_invalid(ino))
      && ino != 0
      && data == old(data[ino := File.empty])
      ensures !ok ==> data == old(data)
    {
      var i;
      ok, ino, i := fs.allocInode(txn, Inode.FileType);
      if !ok {
        return;
      }
      assert this !in fs.Repr;
      fs.finishInode(txn, ino, i);
      assert old(is_invalid(ino)) by {
        assert old(is_of_type(ino, fs.types[ino]));
        reveal is_of_type();
      }
      data := data[ino := File.empty];

      // NOTE(tej): this assertion takes far longer than I expected
      assert is_file(ino);
      mk_file_type(ino);
      mk_data_at(ino);
      ValidData_change_one(ino);

      assert ValidRoot() by { reveal ValidRoot(); }
    }

    static method writeEmptyDirToFs(fs: TypedFilesys, txn: Txn, ino: Ino, i: Inode.Inode)
      returns (ok: bool)
      modifies fs.Repr
      requires fs.ValidIno(ino, i) ensures ok ==> fs.Valid()
      requires fs.has_jrnl(txn)
      requires fs.data[ino] == []
      ensures fs.types_unchanged()
      ensures ok ==> fs.data == old(fs.data[ino := Dirents.zero.enc()])
    {
      var i := i;
      var emptyDir := NewBytes(4096);
      assert emptyDir.data == Dirents.zero.enc() by {
        Dirents.zero_enc();
      }
      ok, i := fs.append(txn, ino, i, emptyDir);
      if !ok {
        return;
      }
      assert fs.data[ino] == Dirents.zero.enc();

      fs.finishInode(txn, ino, i);
    }

    // private
    //
    // creates a directory disconnected from the file system (which is perfectly
    // legal but useless for most clients)
    method allocDir(txn: Txn) returns (ok: bool, ino: Ino)
      modifies Repr
      requires Valid() ensures ok ==> Valid()
      requires fs.has_jrnl(txn)
      ensures ok ==>
      && old(is_invalid(ino))
      && ino != 0
      && data == old(data[ino := File.emptyDir])
      && dirents == old(dirents[ino := Dirents.zero])
      && is_dir(ino)
    {
      var i;
      ok, ino, i := fs.allocInode(txn, Inode.DirType);
      if !ok {
        return;
      }
      assert old(is_invalid(ino)) by {
        assert old(is_of_type(ino, fs.types[ino]));
        reveal is_of_type();
      }

      assert this !in fs.Repr;
      ok := writeEmptyDirToFs(fs, txn, ino, i);
      if !ok {
        return;
      }

      dirents := dirents[ino := Dirents.zero];
      data := data[ino := File.emptyDir];
      assert File.emptyDir.DirFile?;
      assert is_dir(ino);

      Dirents.zero_dir();
      assert is_dir(ino);
      mk_dir_type(ino);
      mk_data_at(ino);
      ValidData_change_one(ino);

      assert ValidRoot() by { reveal ValidRoot(); }
    }

    // linkInode inserts a new entry e' into d_ino
    //
    // requires that e'.name is not already in the directory (in that case we
    // need to insert in a slightly different way that isn't implemented)
    method linkInode(txn: Txn, d_ino: Ino, dents: MemDirents, e': MemDirEnt)
      returns (ok: bool)
      modifies Repr, dents.Repr, e'.name
      requires Valid()
      ensures ok ==> Valid()
      requires fs.has_jrnl(txn)
      requires dents.Valid() && e'.Valid()
      requires is_dir(d_ino) && dirents[d_ino] == dents.val
      requires e'.used() && dents.val.findName(e'.path()) >= 128
      ensures ok ==>
      && data == old(
      var d0 := data[d_ino].dir;
      var d' := DirFile(d0[e'.path() := e'.ino]);
      data[d_ino := d'])
    {
      assert data[d_ino] == DirFile(dents.val.dir) by {
        get_data_at(d_ino);
      }
      var i := dents.findFree();
      if !(i < 128) {
        // no space in directory
        ok := false;
        return;
      }
      ghost var path := e'.path();
      ghost var ino := e'.ino;
      ghost var d := dents.val.dir;
      dents.insert_ent(i, e');
      ghost var d' := dents.val.dir;
      assert d' == d[path := ino];
      ok := writeDirents(txn, d_ino, dents);
      if !ok {
        return;
      }
      assert data[d_ino] == DirFile(d');
    }

    method CREATE(txn: Txn, d_ino: Ino, name: Bytes)
      returns (r: Result<Ino>)
      modifies Repr, name
      requires name.Valid()
      requires Valid() ensures r.Ok? ==> Valid()
      requires fs.has_jrnl(txn)
      ensures r.Ok? ==>
      (var ino := r.v;
      && is_pathc(old(name.data))
      && old(is_dir(d_ino))
      && old(is_invalid(ino))
      && data == old(
        var d := data[d_ino].dir;
        var d' := DirFile(d[name.data := ino]);
        data[ino := File.empty][d_ino := d'])
      )
    {
      var is_path := Pathc?(name);
      if !is_path {
        // could also have 0s in it but whatever
        return Err(NameTooLong);
      }
      var dents_r := readDirents(txn, d_ino);
      if dents_r.Err? {
        return dents_r.Coerce();
      }
      var dents := dents_r.v;
      var ok, ino := allocFile(txn);
      if !ok {
        return Err(NoSpc);
      }
      assert ino_ok: ino !in old(data);
      var name_opt := dents.findName(name);
      if name_opt.Some? {
        // TODO: support creating a file and overwriting existing (rather than
        // failing here)
        return Err(ServerFault);
      }
      var e' := MemDirEnt(name, ino);

      assert dents.Repr !! Repr;
      // NOTE(tej): when e.name was missing from this method's modifies clause,
      // this just kept timing out rather than reporting a modifies clause error
      ok := linkInode(txn, d_ino, dents, e');
      if !ok {
        return Err(NoSpc);
      }
      // assert data == old(data[ino := File.empty][d_ino := DirFile(d')]);
      reveal ino_ok;
      return Ok(ino);
    }

    method GETATTR(txn: Txn, ino: Ino)
      returns (r: Result<Attributes>)
      modifies fs.fs.fs.fs
      requires Valid() ensures Valid()
      requires fs.has_jrnl(txn)
      ensures r.ErrBadHandle? ==> ino !in data
      ensures r.Ok? ==>
          (var attrs := r.v;
          && ino in data
          && attrs.is_dir == data[ino].DirFile?
          && data[ino].ByteFile? ==> attrs.size as nat == |data[ino].data|
          && data[ino].DirFile? ==> attrs.size as nat == 4096
          )
    {
      var ok, i := fs.startInode(txn, ino);
      if !ok {
        assert is_invalid(ino) by { reveal is_of_type(); }
        return Err(BadHandle);
      }
      if i.meta.ty.DirType? {
        assert is_dir(ino) by { reveal is_of_type(); }
        //var dents := readDirentsInode(txn, ino, i);
        fs.finishInodeReadonly(ino, i);
        // NOTE: not sure what the size of a directory is supposed to be, so
        // just return its encoded size in bytes
        var attrs := Attributes(true, 4096);
        return Ok(attrs);
      }
      // is a file
      assert i.meta.ty.FileType?;
      assert is_file(ino) by { reveal is_of_type(); }
      fs.finishInodeReadonly(ino, i);
      var attrs := Attributes(false, i.sz);
      return Ok(attrs);
    }

    method SETATTRsize(txn: Txn, ino: Ino, sz: uint64)
      returns (r:Result<()>, ghost junk: seq<byte>)
      modifies Repr
      requires Valid() ensures r.Ok? ==> Valid()
      requires fs.has_jrnl(txn)
      ensures r.ErrBadHandle? ==> ino !in data
      ensures r.ErrIsDir? ==> is_dir(ino)
      ensures r.Ok? ==>
      && old(is_file(ino))
      && (var d0 := old(data[ino].data);
        var d' := ByteFs.ByteFilesys.setSize_with_junk(d0, sz as nat, junk);
        && (sz as nat > |d0| ==> |junk| == sz as nat - |d0|)
        && data == old(data[ino := ByteFile(d')]))
    {
      junk := [];
      if sz > Inode.MAX_SZ_u64 {
        r := Err(FBig);
        return;
      }
      var i_r := openFile(txn, ino);
      if i_r.Err? {
        r := i_r.Coerce();
        return;
      }
      var i := i_r.v;
      assert dirents == old(dirents);
      invert_file(ino);
      ghost var d0: seq<byte> := old(fs.data[ino]);
      assert d0 == old(data[ino].data) by {
        get_data_at(ino);
      }

      fs.inode_metadata(ino, i);
      assert this !in fs.Repr;

      i, junk := fs.setSize(txn, ino, i, sz);
      fs.finishInode(txn, ino, i);

      ghost var d' := ByteFs.ByteFilesys.setSize_with_junk(d0, sz as nat, junk);
      data := data[ino := ByteFile(d')];

      assert Valid() by {
        file_change_valid(ino, d');
      }

      r := Ok(());
      return;
    }

    method openFile(txn: Txn, ino: Ino)
      returns (r:Result<Inode.Inode>)
      modifies fs.fs.fs.fs
      requires Valid()
      requires fs.has_jrnl(txn)
      ensures r.Ok? ==>
      && ValidIno(ino, r.v)
      && fs.inode_unchanged(ino, r.v)
      && is_file(ino)
      && old(is_file(ino))
      ensures !r.Ok? ==> Valid()
      ensures fs.data == old(fs.data)
      ensures r.ErrBadHandle? ==> is_invalid(ino)
      ensures r.ErrIsDir? ==> is_dir(ino)
      ensures r.Err? ==> r.err.BadHandle? || r.err.IsDir?
      ensures unchanged(this)
      ensures dirents == old(dirents)
    {
      var ok, i := fs.startInode(txn, ino);
      if !ok {
        assert is_invalid(ino) by { reveal is_of_type(); }
        return Err(BadHandle);
      }
      if i.meta.ty.DirType? {
        assert is_dir(ino) by { reveal is_of_type(); }
        fs.finishInodeReadonly(ino, i);
        // assert ValidFiles() by { reveal ValidFiles(); }
        return Err(IsDir);
      }
      assert old(is_file(ino)) && is_file(ino) by { reveal is_of_type(); }
      return Ok(i);
    }

    twostate lemma file_change_valid(ino: Ino, d': seq<byte>)
      requires old(Valid()) && fs.Valid()
      requires old(is_file(ino))
      requires fs.data == old(fs.data[ino := d'])
      requires fs.types_unchanged()
      requires dirents == old(dirents)
      requires data == old(data[ino := ByteFile(d')])
      ensures Valid()
    {
      assert old(this).is_of_type(ino, old(fs.types)[ino]) by {
        reveal is_of_type();
      }
      assert is_of_type(ino, fs.types[ino]) by {
        assert is_file(ino);
        reveal is_of_type();
      }
      mk_data_at(ino);
      ValidData_change_one(ino);
      assert ValidRoot() by { reveal ValidRoot(); }
    }

    // TODO: add support for writes to arbitrary offsets
    method Append(txn: Txn, ino: Ino, bs: Bytes)
      returns (r: Result<()>)
      modifies Repr, bs
      requires Valid()
      // nothing to say in error case (need to abort)
      ensures r.Ok? ==> Valid()
      requires fs.has_jrnl(txn)
      requires bs.Valid() && 0 < bs.Len() <= 4096
      ensures r.ErrBadHandle? ==> ino !in old(data)
      ensures (r.Err? && r.err.Inval?) ==> ino in old(data) && old(data[ino].DirFile?)
      ensures r.Ok? ==>
      && ino in old(data) && old(data[ino].ByteFile?)
      && data == old(
      var d := data[ino].data;
      var d' := d + bs.data;
      data[ino := ByteFile(d')])
    {
      var i_r := openFile(txn, ino);
      if i_r.Err? {
        if i_r.err.IsDir? {
          return Err(Inval);
        }
        return i_r.Coerce();
      }
      var i := i_r.v;
      assert dirents == old(dirents);
      invert_file(ino);
      assert ValidIno(ino, i);
      ghost var d0: seq<byte> := old(fs.data[ino]);
      assert d0 == old(data[ino].data) by {
        get_data_at(ino);
      }
      if i.sz + bs.Len() > Inode.MAX_SZ_u64 {
        // fs.finishInodeReadonly(ino, i);
        return Err(FBig);
      }
      fs.inode_metadata(ino, i);
      assert this !in fs.Repr;
      var ok;
      ok, i := fs.append(txn, ino, i, bs);
      if !ok {
        // fs.finishInode(txn, ino, i);
        return Err(NoSpc);
      }

      fs.finishInode(txn, ino, i);

      ghost var f' := ByteFile(d0 + old(bs.data));
      data := data[ino := f'];

      assert Valid() by {
        file_change_valid(ino, d0 + old(bs.data));
      }
      return Ok(());
    }

    method READ(txn: Txn, ino: Ino, off: uint64, len: uint64)
      returns (r: Result<Bytes>)
      modifies fs.fs.fs.fs
      requires Valid() ensures r.Ok? ==> Valid()
      requires fs.has_jrnl(txn)
      ensures r.ErrBadHandle? ==> ino !in data
      ensures r.ErrInval? ==> ino in data && data[ino].DirFile?
      ensures unchanged(this)
      ensures r.Ok? ==>
      (var bs := r.v;
      && ino in data && data[ino].ByteFile?
      && off as nat + len as nat <= |data[ino].data|
      && bs.data == data[ino].data[off as nat..off as nat + len as nat]
      )
    {
      if len > 4096 {
        // we should really return a short read
        var bs := NewBytes(0);
        return Err(ServerFault);
      }
      var i_r := openFile(txn, ino);
      if i_r.Err? {
        if i_r.err.IsDir? {
          return Err(Inval);
        }
        return i_r.Coerce();
      }
      var i := i_r.v;
      var bs, ok := fs.read(txn, ino, i, off, len);
      if !ok {
        // TODO: I believe this should never happen, short reads are supposed to
        // return partial data and an EOF flag
        return Err(ServerFault);
      }
      get_data_at(ino);
      assert Valid() by {
        assert ValidData() by {
          reveal Valid_data_at();
        }
      }
      return Ok(bs);
    }

    method {:timiLimitMultiplier 2} MKDIR(txn: Txn, d_ino: Ino, name: Bytes)
      returns (r: Result<Ino>)
      modifies Repr, name
      requires Valid() ensures r.Ok? ==> Valid()
      requires fs.has_jrnl(txn)
      requires name.Valid()
      ensures (r.Err? && r.err.Exist?) ==>
      && old(is_dir(d_ino))
      && is_pathc(name.data)
      && name.data in old(data[d_ino].dir)
      ensures r.Ok? ==>
      (var ino := r.v;
      && old(is_dir(d_ino))
      && old(is_invalid(ino))
      && old(is_pathc(name.data))
      && data == old(
        var d := data[d_ino].dir;
        var d' := DirFile(d[name.data := ino]);
        data[ino := File.emptyDir][d_ino := d'])
      )
    {
      var is_path := Pathc?(name);
      if !is_path {
        // could also have 0s in it but whatever
        return Err(NameTooLong);
      }
      var dents_r := readDirents(txn, d_ino);
      if dents_r.Err? {
        return dents_r.Coerce();
      }
      var dents := dents_r.v;
      assert dents.Repr !! Repr;
      assert name !in Repr;
      assert is_dir(d_ino);
      get_data_at(d_ino);
      var name_opt := dents.findName(name);
      if name_opt.Some? {
        dents.val.findName_found(name.data);
        return Err(Exist);
      }

      var ok, ino := allocDir(txn);
      if !ok {
        return Err(NoSpc);
      }
      assert ino != d_ino;

      var e' := MemDirEnt(name, ino);
      assert name.data == old(name.data);
      assert dents.Valid() && e'.Valid() && e'.used();
      ok := linkInode(txn, d_ino, dents, e');
      if !ok {
        return Err(NoSpc);
      }
      return Ok(ino);
    }

    method LOOKUP(txn: Txn, d_ino: Ino, name: Bytes)
      returns (r:Result<Ino>)
      modifies fs.fs.fs.fs
      requires Valid() ensures Valid()
      requires fs.has_jrnl(txn)
      requires is_pathc(name.data)
      ensures r.ErrBadHandle? ==> d_ino !in data
      ensures r.ErrNoent? ==> is_dir(d_ino) && name.data !in data[d_ino].dir
      ensures r.Ok? ==>
      (var ino := r.v;
      && is_dir(d_ino)
      && name.data in data[d_ino].dir && data[d_ino].dir[name.data] == ino && ino != 0
      )
    {
      var dents_r := readDirents(txn, d_ino);
      if dents_r.Err? {
        return dents_r.Coerce();
      }
      var dents := dents_r.v;
      assert DirFile(dents.dir()) == data[d_ino] by {
        get_data_at(d_ino);
      }
      var name_opt := dents.findName(name);
      if name_opt.None? {
        dents.val.findName_not_found(name.data);
        return Err(Noent);
      }
      var ino: Ino := name_opt.x.1;
      dents.val.findName_found(name.data);
      return Ok(ino);
    }

    // this is a low-level function that deletes an inode (currently restricted
    // to files) from the tree
    method removeInode(txn: Txn, ino: Ino)
      returns (r: Result<()>)
      modifies Repr
      requires Valid() ensures Valid()
      requires fs.has_jrnl(txn)
      ensures r.ErrBadHandle? ==> is_invalid(ino) && data == old(data) == old(map_delete(data, ino))
      ensures r.ErrIsDir? ==> is_dir(ino) && data == old(data) && dirents == old(dirents)
      ensures r.Err? ==> r.err.BadHandle? || r.err.IsDir?
      ensures r.Ok? ==>
      && old(is_file(ino))
      && data == old(map_delete(data, ino))
      && dirents == old(dirents)
    {
      var ok, i := fs.startInode(txn, ino);
      if !ok {
        assert is_invalid(ino) by { reveal is_of_type(); }
        Std.map_delete_id(data, ino);
        return Err(BadHandle);
      }
      if i.meta.ty == Inode.DirType {
        // TODO: removeInode doesn't yet support directories
        assert is_dir(ino) by { reveal is_of_type(); }
        fs.finishInodeReadonly(ino, i);
        return Err(IsDir);
      }
      assert is_file(ino) by { reveal is_of_type(); }
      fs.freeInode(txn, ino, i);
      //map_delete_not_in(data, ino);
      data := map_delete(data, ino);

      assert dirents == old(dirents);
      mk_invalid_type(ino);
      mk_data_at(ino);
      ValidData_change_one(ino);
      assert ValidRoot() by { reveal ValidRoot(); }
      return Ok(());
    }

    method unlink(txn: Txn, d_ino: Ino, name: Bytes)
      returns (r: Result<Ino>)
      modifies Repr
      requires Valid() ensures r.Ok? ==> Valid()
      requires fs.has_jrnl(txn)
      requires is_pathc(name.data)
      ensures r.ErrBadHandle? ==> d_ino !in old(data)
      ensures r.ErrNoent? ==> old(is_dir(d_ino)) && name.data !in old(data[d_ino].dir)
      ensures r.ErrNotDir? ==> old(is_file(d_ino))
      ensures !r.ErrIsDir?
      ensures r.Ok? ==>
      && old(is_dir(d_ino))
      && name.data in old(data[d_ino].dir)
      && r.v == old(data[d_ino].dir[name.data])
      && data ==
        (var d0 := old(data[d_ino].dir);
        var d' := map_delete(d0, old(name.data));
        old(data)[d_ino := DirFile(d')])
    {
      ghost var path := name.data;
      var dents_r := readDirents(txn, d_ino);
      if dents_r.Err? {
        return dents_r.Coerce();
      }
      assert was_dir: old(is_dir(d_ino));
      var dents := dents_r.v;
      assert dents.Repr !! Repr;
      assert name !in Repr;

      assert DirFile(dents.dir()) == data[d_ino] by {
        get_data_at(d_ino);
      }
      ghost var d0: Directory := old(data[d_ino].dir);
      var name_opt := dents.findName(name);
      if name_opt.None? {
        dents.val.findName_not_found(path);
        assert path !in data[d_ino].dir;
        return Err(Noent);
      }

      var i := name_opt.x.0;
      var ino := name_opt.x.1;
      dents.val.findName_found(path);
      assert path == dents.val.s[i].name;
      assert name_present: path in old(data[d_ino].dir);

      dents.deleteAt(i);

      ghost var d': Directory := dents.dir();
      assert d' == map_delete(d0, path);

      assert is_dir(d_ino);
      var ok := writeDirents(txn, d_ino, dents);
      if !ok {
        return Err(NoSpc);
      }
      return Ok(ino);
    }

    method REMOVE(txn: Txn, d_ino: Ino, name: Bytes)
      returns (r: Result<()>)
      modifies Repr
      requires Valid() ensures r.Ok? ==> Valid()
      requires fs.has_jrnl(txn)
      requires is_pathc(name.data)
      ensures r.ErrBadHandle? ==> d_ino !in old(data)
      ensures r.ErrNoent? ==>
      && old(is_dir(d_ino))
      && name.data !in old(data[d_ino].dir)
      ensures r.ErrIsDir? ==>
      && old(d_ino in data && data[d_ino].DirFile?)
      && old(name.data) in old(data[d_ino].dir)
      && (var ino := old(data[d_ino].dir[name.data]);
        && ino in old(data)
        && old(data[ino].DirFile?))
      ensures r.Ok? ==>
      && old(is_dir(d_ino))
      && name.data in old(data[d_ino].dir)
      && data ==
        (var d0 := old(data[d_ino].dir);
        var d' := map_delete(d0, old(name.data));
        map_delete(old(data)[d_ino := DirFile(d')], d0[old(name.data)]))
    {
      var old_ino_r := this.unlink(txn, d_ino, name);
      if old_ino_r.Err? {
        return old_ino_r.Coerce();
      }

      var ino := old_ino_r.v;
      var remove_r := removeInode(txn, ino);

      if remove_r.ErrBadHandle? {
        return Ok(());
      }

      if remove_r.Err? {
        assert remove_r.ErrIsDir?;
        return Err(IsDir);
      }

      return Ok(());
    }

    // TODO: would be nice to combine this with removeInode; best way might be
    // to require caller to do the startInode/type checking and only implement
    // the removal part
    method removeInodeDir(txn: Txn, ino: Ino)
      modifies Repr
      requires Valid() ensures Valid()
      requires ino != rootIno
      requires is_dir(ino)
      requires fs.has_jrnl(txn)
      ensures data == old(map_delete(data, ino))
      ensures dirents == old(map_delete(dirents, ino))
    {
      var ok, i := fs.startInode(txn, ino);
      if !ok {
        assert is_invalid(ino) by { reveal is_of_type(); }
        assert false;
      }
      fs.freeInode(txn, ino, i);
      data := map_delete(data, ino);
      dirents := map_delete(dirents, ino);

      mk_invalid_type(ino);
      mk_data_at(ino);
      ValidData_change_one(ino);
      assert ValidRoot() by { reveal ValidRoot(); }
    }

    method RMDIR(txn: Txn, d_ino: Ino, name: Bytes)
      returns (r: Result<()>)
      modifies Repr
      requires Valid() ensures r.Ok? ==> Valid()
      requires fs.has_jrnl(txn)
      requires is_pathc(name.data)
      ensures r.ErrBadHandle? ==> d_ino !in old(data)
      ensures r.ErrNoent? ==>
      && old(is_dir(d_ino))
      && name.data !in old(data[d_ino].dir)
      ensures r.ErrNotDir? ==>
      (&& old(is_file(d_ino)))
      || (&& old(d_ino in data && data[d_ino].DirFile?)
         && old(name.data) in old(data[d_ino].dir)
         && (var ino := old(data[d_ino].dir[name.data]);
           && ino in old(data)
           && old(data[ino].ByteFile?)))
      ensures r.Ok? ==>
      && old(is_dir(d_ino))
      && name.data in old(data[d_ino].dir)
      && data ==
        (var d0 := old(data[d_ino].dir);
        var d' := map_delete(d0, old(name.data));
        map_delete(old(data)[d_ino := DirFile(d')], d0[old(name.data)]))
    {
      var old_ino_r := this.unlink(txn, d_ino, name);
      if old_ino_r.Err? {
        return old_ino_r.Coerce();
      }

      var ino := old_ino_r.v;
      if ino == rootIno {
        return Err(Inval);
      }
      var dents_r := readDirents(txn, ino);
      if dents_r.ErrBadHandle? {
        Std.map_delete_id(data, ino);
        return Ok(());
      }
      if dents_r.ErrNotDir? {
        return Err(NotDir);
      }
      var is_empty := dents_r.v.isEmpty();
      if !is_empty {
        get_data_at(ino);
        assert data[ino].dir != map[];
        return Err(NotEmpty);
      }
      removeInodeDir(txn, ino);

      return Ok(());
    }

    method READDIR(txn: Txn, d_ino: Ino)
      returns (r: Result<seq<MemDirEnt>>)
      modifies fs.fs.fs.fs
      requires Valid() ensures Valid()
      requires fs.has_jrnl(txn)
      ensures r.ErrBadHandle? ==> d_ino !in data
      ensures r.Ok? ==>
      (var dents_seq := r.v;
      && mem_seq_valid(dents_seq)
      && fresh(mem_dirs_repr(dents_seq))
      && d_ino in data
      && data[d_ino].DirFile?
      && seq_to_dir(mem_seq_val(dents_seq)) == data[d_ino].dir
      && |dents_seq| == |data[d_ino].dir|
      )
    {
      var dents_r := readDirents(txn, d_ino);
      if dents_r.Err? {
        return dents_r.Coerce();
      }
      var dents := dents_r.v;
      assert DirFile(dents.dir()) == data[d_ino] by {
        get_data_at(d_ino);
      }
      var dents_seq := dents.usedDents();
      return Ok(dents_seq);
    }

    // TODO:
    //
    // 1. Append (done)
    // 2. Read (done)
    // 3. CreateDir (done)
    // 4. Write
    // 5. Rename (maybe?)
    // 6. Unlink (done)

  }
}
