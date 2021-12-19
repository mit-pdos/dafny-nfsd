package bytes

import "fmt"

// Bytes wraps a byte slice []byte
type Bytes struct {
	Data []byte
	Invalid bool
}

func NewBytes(sz uint64) *Bytes {
	return &Bytes{Data: make([]byte, sz)}
}

func Data(data []byte) *Bytes {
	return &Bytes{Data: data}
}

func (bs *Bytes) Len() uint64 {
	return uint64(len(bs.Data))
}

func (bs *Bytes) Get(i uint64) byte {
	if bs.Invalid {
		panic("bytes invalid")
	}
	return bs.Data[i]
}

func (bs *Bytes) Set(i uint64, b byte) {
	if bs.Invalid {
		panic("bytes invalid")
	}
	bs.Data[i] = b
}

func (bs *Bytes) Append(b byte) {
	if bs.Invalid {
		panic("bytes invalid")
	}
	bs.Data = append(bs.Data, b)
}

func (bs *Bytes) AppendBytes(other *Bytes) {
	if bs.Invalid || other.Invalid {
		panic("bytes invalid")
	}
	if other == bs {
		panic("attempt to append to self")
	}
	bs.Data = append(bs.Data, other.Data...)
}

func (bs *Bytes) Subslice(start uint64, end uint64) {
	if bs.Invalid {
		panic("bytes invalid")
	}
	bs.Data = bs.Data[start:end]
}

func (bs *Bytes) CopySegment(dst uint64, other *Bytes, src uint64, count uint64) {
	if bs.Invalid || other.Invalid {
		panic("bytes invalid")
	}
	if other == bs {
		panic("attempt to CopySegment self")
	}
	copy(bs.Data[dst:], other.Data[src:src+count])
}

func (bs *Bytes) Split(off uint64) *Bytes {
	if bs.Invalid {
		panic("bytes invalid")
	}
	// this "full slice expression" is necessary to make the two Bytes
	// independent (otherwise bs will have the returned Bytes as its capacity,
	// which is overwritten by Append)
	//
	// see https://golang.org/ref/spec#Slice_expressions
	first := bs.Data[:off:off]
	second := bs.Data[off:]
	bs.Data = first
	return &Bytes{Data: second}
}

func (bs *Bytes) Print() {
	if bs.Invalid {
		panic("bytes invalid")
	}
	fmt.Printf("%v", bs.Data)
}
