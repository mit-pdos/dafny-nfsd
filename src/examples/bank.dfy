include "../util/marshal.i.dfy"
include "../jrnl/jrnl.s.dfy"

module Bank {

import Arith
import opened Machine
import opened ByteSlice
import opened JrnlTypes
import opened JrnlSpec
import opened Kinds
import opened Marshal
import C = Collections

/*
Demo of bank transfer using axiomatized journal API
*/
class Bank
{
    ghost var accts: seq<nat>;
    ghost const acct_sum: nat;

    var jrnl: Jrnl;

    static const BankKinds : map<Blkno, Kind> := map[513 as Blkno := KindUInt64 as Kind]

    static function method Acct(n: uint64): (a:Addr)
    requires n < 512
    ensures a.off as nat % kindSize(KindUInt64) == 0
    {
        assert kindSize(6) == 64;
        Arith.mul_mod(n as nat, 64);
        Addr(513, n*64)
    }

    static predicate acct_val(jrnl: Jrnl, acct: uint64, val: nat)
    reads jrnl
    requires jrnl.Valid()
    requires jrnl.kinds == BankKinds
    requires acct < 512
    {
        jrnl.in_domain(Acct(acct));
        && val < U64.MAX
        && jrnl.data[Acct(acct)] == ObjData(seq_encode([EncUInt64(val as uint64)]))
    }

    // pure version of Valid for crash condition
    static predicate ValidState(jrnl: Jrnl, accts: seq<nat>, acct_sum: nat)
        reads jrnl
    {
        && jrnl.Valid()
        && jrnl.kinds == BankKinds
        && |accts| == 512
        && (forall n: uint64 :: n < 512 ==>
            var acct := Acct(n);
             && acct in jrnl.data
             && jrnl.size(acct) == 64
             && accts[n] < U64.MAX
             && acct_val(jrnl, n, accts[n]))
        && acct_sum == C.sum_nat(accts)
    }

    predicate Valid()
        reads this, jrnl
    {
        && ValidState(jrnl, accts, acct_sum)
    }

    static method encode_acct(x: uint64) returns (bs:Bytes)
    ensures fresh(bs)
    ensures bs.Valid()
    ensures seq_encode([EncUInt64(x)]) == bs.data
    {
        bs := NewBytes(8);
        IntEncoding.UInt64Put(x, 0, bs);
    }

    static method decode_acct(bs:Bytes, ghost x: nat) returns (x': uint64)
    requires x < U64.MAX
    requires bs.Valid()
    requires seq_encode([EncUInt64(x as uint64)]) == bs.data
    ensures x' as nat == x
    {
        x' := UInt64Decode(bs, 0, x as uint64);
    }

    constructor Init(d: Disk, init_bal: uint64)
    ensures Valid()
    ensures forall n: nat:: n < 512 ==> accts[n] == init_bal as nat
    ensures acct_sum == 512*(init_bal as nat)
    {
        // BUG: without the "as" operators in the next line, Dafny makes the type
        // of the map display expression map<int,int>.
        var kinds := map[513 as Blkno := KindUInt64 as Kind];
        var jrnl := NewJrnl(d, kinds);

        // help with constant calculation
        assert kindSize(6) == 64;
        assert kindSize(jrnl.kinds[513]) == 64;
        forall n: uint64 | n < 512
            ensures Acct(n) in jrnl.data
            ensures jrnl.size(Acct(n)) == 64
        {
            ghost var acct := Acct(n);
            jrnl.in_domain(acct);
            jrnl.has_size(acct);
        }

        var txn := jrnl.Begin();
        var n := 0;
        while n < 512
        modifies jrnl
        invariant txn.jrnl == jrnl
        invariant txn.Valid()
        invariant n <= 512
        invariant forall k {:trigger Acct(k)} :: 0 <= k < n ==> acct_val(jrnl, k, init_bal as nat)
        {
            var acct := Acct(n);
            jrnl.in_domain(acct);
            var init_acct := encode_acct(init_bal);
            txn.Write(acct, init_acct);
            n := n + 1;
        }
        var _ := txn.Commit();

        this.jrnl := jrnl;

        // NOTE: this was really annoying to figure out - turns out needed the
        // accounts to be a repeat of nats instead of uint64
        C.sum_repeat(init_bal as nat, 512);
        accts := C.repeat(init_bal as nat, 512);
        acct_sum := 512*(init_bal as nat);

        forall n: uint64 | n < 512
            ensures (var acct := Acct(n);
                     acct in jrnl.data)
        {
            ghost var acct := Acct(n);
            jrnl.in_domain(acct);
        }

    }

    constructor Recover(jrnl: Jrnl, ghost accts: seq<nat>, ghost acct_sum: nat)
        requires ValidState(jrnl, accts, acct_sum)
        ensures Valid()
        ensures this.jrnl == jrnl
        ensures this.accts == accts
        ensures this.acct_sum == acct_sum
    {
        this.jrnl := jrnl;
        this.accts := accts;
        this.acct_sum := acct_sum;
    }

    ghost method inc_acct(acct: uint64, amt: int)
        modifies this
        requires acct as nat < |accts|
        requires no_overflow(accts[acct], amt)
        ensures accts == old(accts[acct as nat:=accts[acct] + amt])
        ensures C.sum_nat(accts) == old(C.sum_nat(accts) + amt)
    {
        C.sum_update(accts, acct as nat, accts[acct] as nat + amt);
        accts := accts[acct as nat:=accts[acct] + amt];
    }

    method Transfer(acct1: uint64, acct2: uint64)
    requires Valid() ensures Valid()
    modifies this, jrnl
    requires && acct1 < 512 && acct2 < 512 && acct1 != acct2
    requires && no_overflow(accts[acct1], -1) && no_overflow(accts[acct2], 1)
    ensures accts == old(accts[acct1 as nat:=accts[acct1]-1][acct2 as nat:=accts[acct2]+1])
    {
        var txn := jrnl.Begin();
        var x := txn.Read(Acct(acct1), 64);
        var acct1_val: uint64 := decode_acct(x, accts[acct1]);
        var x' := encode_acct(acct1_val-1);
        txn.Write(Acct(acct1), x');
        inc_acct(acct1, -1);

        x := txn.Read(Acct(acct2), 64);
        var acct2_val: uint64 := decode_acct(x, accts[acct2]);
        x' := encode_acct(acct2_val+1);
        txn.Write(Acct(acct2), x');
        inc_acct(acct2, 1);
        var _ := txn.Commit();
    }

    method Get(acct: uint64)
        returns (bal: uint64)
        requires Valid()
        requires acct < 512
        ensures bal as nat == accts[acct]
    {
        var txn := jrnl.Begin();
        var x := txn.Read(Acct(acct), 64);
        bal := decode_acct(x, accts[acct]);
        // need to commit or abort (even of read-only)
        var _ := txn.Commit();
    }

    // this is kind of silly but it gets the point across (without requiring the
    // reader to understand Valid())
    lemma Audit()
        requires Valid()
        ensures C.sum_nat(accts) == acct_sum
    {
    }
}

}
