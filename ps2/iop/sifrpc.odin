// sifcmd's RPC servers as IOP modules register them (PS_IRX=1). A module
// registers a server on a queue (sceSifRegisterRpc), names the thread that
// serves the queue (sceSifSetRpcQueue) and runs the queue's loop on it
// (sceSifRpcLoop): each request runs the server's function on that thread,
// then the EE gets its reply and RPC_END.
//
// The EE binds a server id as without PS_IRX (sif_command): to the HLE's
// descriptor, which holds the id. A call is routed by that id when it
// arrives, so a bind made before the module registered reaches the module
// all the same. The EE's request, which it sent to the HLE descriptor's
// buffer, is copied to the server's buffer then, as retail's EE writes that
// buffer when it calls.
package ps2_iop

import "core:fmt"
import "ps:core"
import cpu "../cpu"
import mem "../mem"
import r3000 "ps:psx/cpu"

IOP_RPC_SERVERS :: 32
IOP_RPC_QUEUES :: 8
// The requests queued and not yet run, every queue's together.
IOP_RPC_REQS :: 16

// A call the EE made, as its packet gave it.
Iop_Rpc_Req :: struct {
	rec_id, pkt, rpc_id, client: u32,
	fno, size, receive, rsize:   u32,
	server:                      u32, // the HLE descriptor the EE bound
	sid, sd, qd:                 u32, // the module's server and its queue
}

Iop_Rpc_Server :: struct {
	sid, sd, qd: u32,
}

Iop_Rpc_Queue :: struct {
	qd, thread: u32,
	busy:       bool, // its thread runs a request
	cur:        Iop_Rpc_Req, // the one it runs
}

Iop_Rpc :: struct {
	servers:   [IOP_RPC_SERVERS]Iop_Rpc_Server,
	n_servers: int,
	queues:    [IOP_RPC_QUEUES]Iop_Rpc_Queue,
	n_queues:  int,
	reqs:      [IOP_RPC_REQS]Iop_Rpc_Req, // first come first
	n_reqs:    int,
	calls:     u64, // requests that reached a server's function
}

// Emulated state, snapshotted (sif_snap) and reset with the loader.
iop_rpc: Iop_Rpc

// sifcmd's RPC functions, as sifcmd_fn.
sifrpc_fn :: proc(fno: u32) -> (v0: u32, ok: bool) {
	r := &r3000.state.r
	a0, a1, a2, a3 := r[4], r[5], r[6], r[7]
	switch fno {
	case 14: // sceSifInitRpc(mode): sif_command serves the system commands
		return 0, true
	case 17: // sceSifRegisterRpc(sd, sid, func, buf, cfunc, cbuf, qd)
		cfunc, cbuf, qd := r32(r[29] + 16), r32(r[29] + 20), r32(r[29] + 24)
		w32(a0, a1)
		w32(a0 + 4, a2)
		w32(a0 + 8, a3)
		w32(a0 + 0x10, cfunc)
		w32(a0 + 0x14, cbuf)
		w32(a0 + 0x38, 0)
		w32(a0 + 0x3c, 0)
		w32(a0 + 0x40, qd)
		rpc_register(a1, a0, qd)
		return 0, true
	case 19: // sceSifSetRpcQueue(qd, thread id)
		w32(a0, a1)
		for o := u32(4); o <= 0x14; o += 4 {w32(a0 + o, 0)}
		rpc_queue_set(a0, a1)
		return 0, true
	case 22: // sceSifRpcLoop(qd): returns only on a thread that cannot sleep
		return rpc_loop(a0), true
	case 24: // sceSifRemoveRpc(sd, qd)
		return rpc_remove(a0, a1), true
	case 25: // sceSifRemoveRpcQueue(qd)
		return rpc_remove_queue(a0), true
	}
	return 0, false
}

// A server the HLE runs on a guest thread of its own: sid at descriptor sd,
// on queue qd that `thread` serves. The caller checks there is room for
// both (rpc_host_room).
rpc_host_server :: proc(sid, sd, qd, thread: u32) {
	assert(rpc_host_room(), "iop: rpc_host_server with no room")
	rpc_queue_set(qd, thread)
	rpc_register(sid, sd, qd)
}

// Whether a server and a queue can be added.
rpc_host_room :: proc() -> bool {
	return iop_rpc.n_servers < IOP_RPC_SERVERS && iop_rpc.n_queues < IOP_RPC_QUEUES
}

// Adds server sid at descriptor sd on queue qd. A sid already served keeps
// its server too, as retail appends to the queue's list without a check:
// rpc_server picks between them, and dropping one leaves the other.
@(private = "file")
rpc_register :: proc(sid, sd, qd: u32) {
	s := &iop_rpc
	i := 0
	for i < s.n_servers && s.servers[i].sd != sd {i += 1}
	if i == s.n_servers {
		if s.n_servers == IOP_RPC_SERVERS {
			core.compat_unknown(.Iop_Rpc, sid, sub = max(u32))
			fmt.eprintfln("iop: rpc server %08x: no room, left to the HLE", sid)
			return
		}
		s.n_servers += 1
	}
	s.servers[i] = {sid, sd, qd}
	if cpu.debug >= 1 {fmt.eprintfln("iop: rpc server %08x registered, sd %x qd %x", sid, sd, qd)}
}

@(private = "file")
rpc_queue_set :: proc(qd, thread: u32) {
	s := &iop_rpc
	q := rpc_queue(qd)
	if q == nil {
		if s.n_queues == IOP_RPC_QUEUES {
			fmt.eprintfln("iop: rpc queue %x: no room", qd)
			return
		}
		q = &s.queues[s.n_queues]
		s.n_queues += 1
	}
	q^ = {qd = qd, thread = thread}
}

// sceSifRemoveRpc: takes server sd off queue qd, the requests queued for it
// lost (rpc_drop_server). What retail's walk of the queue's list returns: sd
// when it was the queue's first, else the server before it there; 0, and
// nothing done, when sd is not on qd. The guest's list words are not kept
// (rpc_register), so none is written.
@(private = "file")
rpc_remove :: proc(sd, qd: u32) -> u32 {
	s := &iop_rpc
	prev := sd
	for v, i in s.servers[:s.n_servers] {
		if v.qd != qd {continue}
		if v.sd == sd {
			rpc_drop_server(i)
			return prev
		}
		prev = v.sd
	}
	return 0
}

// sceSifRemoveRpcQueue: takes queue qd off the list calls are routed by, and
// with it its servers, whose calls retail no longer finds; the requests
// queued for them are lost (rpc_drop_queue). One its thread runs ends as
// usual. Returns as rpc_remove, by the order the queues were set.
@(private = "file")
rpc_remove_queue :: proc(qd: u32) -> u32 {
	s := &iop_rpc
	prev := qd
	for q in s.queues[:s.n_queues] {
		if q.qd == qd {
			rpc_drop_queue(qd)
			return prev
		}
		prev = q.qd
	}
	return 0
}

// The server that takes calls to sid, -1 if none: as retail's search, the
// first on the first queue set, then in the order registered; one whose
// queue is not set yet comes last.
@(private)
rpc_server :: proc(sid: u32) -> int {
	s := &iop_rpc
	found, rank := -1, IOP_RPC_QUEUES + 1
	for v, i in s.servers[:s.n_servers] {
		if v.sid != sid {continue}
		r := 0
		for r < s.n_queues && s.queues[r].qd != v.qd {r += 1}
		if r == s.n_queues {r = IOP_RPC_QUEUES}
		if r < rank {found, rank = i, r}
	}
	return found
}

@(private = "file")
rpc_queue :: proc(qd: u32) -> ^Iop_Rpc_Queue {
	s := &iop_rpc
	for &q in s.queues[:s.n_queues] {
		if q.qd == qd {return &q}
	}
	return nil
}

// sif_command's RPC_CALL with PS_IRX=1, the packet at `a`, to server `sid`:
// whether a module's server takes it. One that does sends RPC_END once its
// function returns, which may be after this; one whose queue's thread is
// gone is dropped (rpc_gone) and the call left to the HLE.
iop_rpc_call :: proc(a, sid: u32) -> bool {
	s := &iop_rpc
	i := rpc_server(sid)
	if i < 0 {return false}
	v := s.servers[i]
	arg :: proc(a: u32, n: u32) -> u32 {return iop_u32(a + 16 + 4 * n)^}
	req := Iop_Rpc_Req {
		rec_id  = arg(a, 0),
		pkt     = arg(a, 1),
		rpc_id  = arg(a, 2),
		client  = arg(a, 3),
		fno     = arg(a, 4),
		size    = arg(a, 5),
		receive = arg(a, 6),
		rsize   = arg(a, 7),
		server  = arg(a, 9),
		sid     = sid,
		sd      = v.sd,
		qd      = v.qd,
	}
	q := rpc_queue(v.qd)
	t := th_find(q.thread) if q != nil else nil
	if t == nil || t.status == .Dormant {
		rpc_gone(v.qd)
		return false
	}
	buf := r32(v.sd + 8)
	if !rpc_fits(buf, req.size) {
		core.compat_unknown(.Iop_Rpc, sid, sub = req.fno)
		fmt.eprintfln("iop: rpc %08x fno %d: %d bytes do not fit the buffer at %x", sid, req.fno, req.size, buf)
		req.size = 0
	}
	if s.n_reqs == IOP_RPC_REQS {
		rpc_lost(req)
		return true
	}
	copy(iop_ram_at(buf, req.size), iop_mem(req.server + 0x100, req.size))
	s.reqs[s.n_reqs] = req
	s.n_reqs += 1
	if cpu.debug >= 1 {fmt.eprintfln("iop: rpc %08x fno %d queued for thread %d, busy %v, %d queued", sid, req.fno, q.thread, q.busy, s.n_reqs)}
	if !q.busy {th_wakeup(q.thread)}
	iop_sync(cpu.state.cycles)
	iop_sched.start_done = false
	th_schedule(r3000.state.cycles + IOP_SLICE)
	iop_wake_set()
	return true
}

// Whether the `size` bytes of the EE's request fit the server's buffer at
// IOP address `buf`: the HLE descriptor's buffer they came from, IOP RAM,
// and the block that holds buf when one does.
@(private = "file")
rpc_fits :: proc(buf, size: u32) -> bool {
	p := buf & 0x1fffffff
	if size > 0xff00 || p >= IOP_RAM_SIZE || size > IOP_RAM_SIZE - p {return false}
	for b in sys_blocks {
		if p - b.addr < b.size {return size <= b.addr + b.size - p}
	}
	return true
}

// sceSifRpcLoop on the running thread: runs queue qd's requests in the order
// they came, and sleeps while there is none. What a sleep that failed
// returned.
@(private = "file")
rpc_loop :: proc(qd: u32) -> u32 {
	s := &iop_rpc
	for {
		req: Iop_Rpc_Req
		found := false
		for v, i in s.reqs[:s.n_reqs] {
			if v.qd != qd {continue}
			req, found = v, true
			rpc_req_remove(i)
			break
		}
		q := rpc_queue(qd)
		if q == nil || !found {
			if q != nil {q.busy = false}
			if v := th_sleep(); v != KE_OK {return v}
			continue
		}
		q.busy, q.cur = true, req
		rpc_exec(req)
		if q = rpc_queue(qd); q != nil {q.busy = false}
	}
}

@(private = "file")
rpc_req_remove :: proc(i: int) {
	s := &iop_rpc
	copy(s.reqs[i:s.n_reqs - 1], s.reqs[i + 1:s.n_reqs])
	s.n_reqs -= 1
}

// Runs request req's server function on the running thread, then sends the
// EE rsize bytes from what it returned, and RPC_END; a function returning 0
// sends no bytes.
@(private = "file")
rpc_exec :: proc(req: Iop_Rpc_Req) {
	r := &r3000.state.r
	saved := r^
	r[4], r[5], r[6] = req.fno, r32(req.sd + 8), req.size
	iop_rpc.calls += 1
	if cpu.debug >= 1 {fmt.eprintfln("iop: rpc %08x fno %d size %d", req.sid, req.fno, req.size)}
	r3000.call(r32(req.sd + 4))
	res := r[2]
	r^ = saved
	if res != 0 && req.receive != 0 && req.rsize != 0 {
		src, dst := res & 0x1fffffff, req.receive & 0x0fffffff
		in_iop := src < IOP_RAM_SIZE && req.rsize <= IOP_RAM_SIZE - src
		in_ee := req.receive >> 28 != 7 && dst < mem.RAM_SIZE && req.rsize <= mem.RAM_SIZE - dst
		if in_iop && in_ee {
			copy(mem.ram_slice(req.receive, req.rsize), iop_ram[src:][:req.rsize])
		} else {
			core.compat_unknown(.Iop_Rpc, req.sid, sub = req.fno)
			fmt.eprintfln("iop: rpc %08x fno %d: %d bytes from %x to %x out of range", req.sid, req.fno, req.rsize, res, req.receive)
		}
	}
	sif_reply(SIF_CMD_RPC_END, 0, {req.rec_id, req.pkt, req.rpc_id, req.client, SIF_CMD_RPC_CALL, req.server, 0, 0})
}

// A request that gets no RPC_END, which the EE waits on: a compat row.
@(private = "file")
rpc_lost :: proc(req: Iop_Rpc_Req) {
	core.compat_unknown(.Iop_Rpc, req.sid, sub = req.fno)
	fmt.eprintfln("iop: rpc %08x fno %d gets no RPC_END", req.sid, req.fno)
}

// Queue qd's thread is gone: the queue and its servers are dropped, and the
// request it ran and those queued for it are lost (rpc_lost).
@(private = "file")
rpc_gone :: proc(qd: u32) {
	if cpu.debug >= 1 {fmt.eprintfln("iop: rpc queue %x gone", qd)}
	if q := rpc_queue(qd); q != nil && q.busy {rpc_lost(q.cur)}
	rpc_drop_queue(qd)
}

// Removes queue qd, and its servers and the requests queued for them, which
// are lost (rpc_lost).
@(private = "file")
rpc_drop_queue :: proc(qd: u32) {
	s := &iop_rpc
	for i := s.n_queues - 1; i >= 0; i -= 1 {
		if s.queues[i].qd != qd {continue}
		copy(s.queues[i:s.n_queues - 1], s.queues[i + 1:s.n_queues])
		s.n_queues -= 1
	}
	for i := s.n_reqs - 1; i >= 0; i -= 1 {
		if s.reqs[i].qd != qd {continue}
		rpc_lost(s.reqs[i])
		rpc_req_remove(i)
	}
	for i := s.n_servers - 1; i >= 0; i -= 1 {
		if s.servers[i].qd == qd {rpc_drop_server(i)}
	}
}

// Removes server i; the requests queued for it are lost (rpc_lost).
@(private = "file")
rpc_drop_server :: proc(i: int) {
	s := &iop_rpc
	sd := s.servers[i].sd
	copy(s.servers[i:s.n_servers - 1], s.servers[i + 1:s.n_servers])
	s.n_servers -= 1
	for j := s.n_reqs - 1; j >= 0; j -= 1 {
		if s.reqs[j].sd != sd {continue}
		rpc_lost(s.reqs[j])
		rpc_req_remove(j)
	}
}

// Thread `id` stopped: the queues it served are gone (rpc_gone).
rpc_thread_gone :: proc(id: u32) {
	s := &iop_rpc
	for i := s.n_queues - 1; i >= 0; i -= 1 {
		if i < s.n_queues && s.queues[i].thread == id {rpc_gone(s.queues[i].qd)}
	}
}

// After a failed load: drops each queue in `freed`, the memory its undo
// frees, or whose thread the undo deleted (rpc_gone), and each server with
// its descriptor, function or buffer there. Then what the load removed
// (rpc_remove, rpc_remove_queue) and was there when it began (`saved`) comes
// back where it was: a queue whose thread is still there, then a server whose
// queue is back or was never set. The requests the removal lost stay lost,
// with their rows. A queue the load added that then has no room is a row
// (function number all ones), and is dropped with its servers, each a row as
// well, and the requests queued for them, lost; the one its thread runs ends
// as usual. A server the load added with no room is rpc_register's row.
rpc_undo :: proc(saved: Iop_Rpc, freed: []Sys_Block) {
	s, saved := &iop_rpc, saved
	was := saved.queues[:saved.n_queues]
	for i := s.n_queues - 1; i >= 0; i -= 1 {
		if i >= s.n_queues {continue}
		q := s.queues[i]
		if sys_in(freed, q.qd) || th_find(q.thread) == nil {rpc_gone(q.qd)}
	}
	for i := s.n_servers - 1; i >= 0; i -= 1 {
		if i >= s.n_servers {continue}
		sd := s.servers[i].sd
		if sys_in(freed, sd) || sys_in(freed, r32(sd + 4)) || sys_in(freed, r32(sd + 8)) {rpc_drop_server(i)}
	}

	queues: [IOP_RPC_QUEUES]Iop_Rpc_Queue
	n := 0
	for v in was {
		if q := rpc_queue(v.qd); q != nil {
			queues[n] = q^
		} else if !sys_in(freed, v.qd) && th_find(v.thread) != nil {
			queues[n] = {qd = v.qd, thread = v.thread}
			if cpu.debug >= 1 {fmt.eprintfln("iop: rpc queue %x a failed load removed is back", v.qd)}
		} else {
			continue
		}
		n += 1
	}
	full: [IOP_RPC_QUEUES]u32
	nf := 0
	for v in s.queues[:s.n_queues] {
		if rpc_set_in(was, v.qd) {continue}
		if n == IOP_RPC_QUEUES {
			full[nf] = v.qd
			nf += 1
			continue
		}
		queues[n] = v
		n += 1
	}
	for qd in full[:nf] {
		core.compat_unknown(.Iop_Rpc, qd, sub = max(u32))
		fmt.eprintfln("iop: rpc queue %x: no room after a failed load, its servers left to the HLE", qd)
		for v in s.servers[:s.n_servers] {
			if v.qd == qd {core.compat_unknown(.Iop_Rpc, v.sid, sub = max(u32))}
		}
		rpc_drop_queue(qd)
	}
	s.queues, s.n_queues = queues, n

	servers: [IOP_RPC_SERVERS]Iop_Rpc_Server
	m := 0
	for v in saved.servers[:saved.n_servers] {
		cur := -1
		for w, i in s.servers[:s.n_servers] {
			if w.sd == v.sd {cur = i}
		}
		if cur >= 0 {
			servers[m] = s.servers[cur]
		} else if !sys_in(freed, v.sd) && (rpc_queue(v.qd) != nil || !rpc_set_in(was, v.qd)) {
			servers[m] = v
			if cpu.debug >= 1 {fmt.eprintfln("iop: rpc server %08x a failed load removed is back", v.sid)}
		} else {
			continue
		}
		m += 1
	}
	for v in s.servers[:s.n_servers] {
		known := false
		for w in saved.servers[:saved.n_servers] {
			if w.sd == v.sd {known = true}
		}
		if known {continue}
		if m == IOP_RPC_SERVERS {
			core.compat_unknown(.Iop_Rpc, v.sid, sub = max(u32))
			fmt.eprintfln("iop: rpc server %08x: no room after a failed load, left to the HLE", v.sid)
			continue
		}
		servers[m] = v
		m += 1
	}
	s.servers, s.n_servers = servers, m
}

// Whether queue qd is one of `queues`.
@(private = "file")
rpc_set_in :: proc(queues: []Iop_Rpc_Queue, qd: u32) -> bool {
	for q in queues {
		if q.qd == qd {return true}
	}
	return false
}
