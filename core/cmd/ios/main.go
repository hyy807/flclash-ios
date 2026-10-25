//go:build ios && cgo

// Package main is the C entry point of the FlClash core for iOS.
//
// On Android the core is reached through gomobile (core/mobile), which gives
// gobind-generated Java classes. iOS has no gobind: the Network Extension and
// the app link a c-archive and call the functions exported below. The ABI here
// matches ios/Runner/IOSCoreBridge.m and ios/NECore/NECoreBridge.m, which are
// shared with the upstream FlClash iOS work (see NOTICE).
//
// Build:
//
//	CGO_ENABLED=1 GOOS=ios GOARCH=arm64 \
//	  CC="$(xcrun --sdk iphoneos --find clang) -arch arm64 -isysroot $(xcrun --sdk iphoneos --show-sdk-path)" \
//	  go build -buildmode=c-archive -o libclash/ios/arm64/libclash.a ./core/cmd/ios
package main

/*
#include <stdlib.h>
#include <mach/mach.h>

#include "bride.h"

static uint64_t phys_footprint(void) {
	task_vm_info_data_t info;
	mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
	if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) {
		return 0;
	}
	return info.phys_footprint;
}

static void flclash_log(const char *level, const char *message) {
	system_log(level, message);
}
*/
import "C"

import (
	"encoding/json"
	"fmt"
	"runtime/debug"
	"sync"
	"sync/atomic"
	"time"
	"unsafe"

	"core"
)

func main() {}

// ---------------------------------------------------------------------------
// C string helpers. Go must never hold a C pointer past the call, and every
// allocation is released on the same goroutine that made it.
// ---------------------------------------------------------------------------

func takeCString(data *C.char) string {
	if data == nil {
		return ""
	}
	value := C.GoString(data)
	C.free(unsafe.Pointer(data))
	return value
}

func releaseObject(callback unsafe.Pointer) {
	if callback != nil {
		C.release_object(callback)
	}
}

func logError(format string, args ...any) {
	message := fmt.Sprintf(format, args...)
	level := C.CString("error")
	defer C.free(unsafe.Pointer(level))
	text := C.CString(message)
	defer C.free(unsafe.Pointer(text))
	C.flclash_log(level, text)
}

func logInfo(message string) {
	level := C.CString("info")
	defer C.free(unsafe.Pointer(level))
	text := C.CString(message)
	defer C.free(unsafe.Pointer(text))
	C.flclash_log(level, text)
}

// invokeResult hands a string back to Objective-C and frees it. The ObjC side
// copies into NSData synchronously before returning.
func invokeResult(callback unsafe.Pointer, data string) {
	if callback == nil {
		return
	}
	text := C.CString(data)
	defer C.free(unsafe.Pointer(text))
	C.result(callback, text)
}

// ---------------------------------------------------------------------------
// Tun callbacks. iOS has no VpnService.protect (no per-uid routing) and no
// /proc, so protect is a no-op and uid lookups report "unknown".
// ---------------------------------------------------------------------------

type tunCallbacks struct {
	handle unsafe.Pointer
}

func (t tunCallbacks) Protect(fd int) bool {
	if t.handle == nil {
		return false
	}
	return C.protect(t.handle, C.int(fd)) != 0
}

func (t tunCallbacks) ResolveUid(protocol int, source, target string) int {
	if t.handle == nil {
		return -1
	}
	s := C.CString(source)
	defer C.free(unsafe.Pointer(s))
	d := C.CString(target)
	defer C.free(unsafe.Pointer(d))
	return int(C.resolve_uid(t.handle, C.int(protocol), s, d))
}

func (t tunCallbacks) ResolvePackage(uid int) string {
	if t.handle == nil {
		return ""
	}
	value := C.resolve_package(t.handle, C.int(uid))
	if value == nil {
		return ""
	}
	defer C.free_string(value)
	return C.GoString(value)
}

// ---------------------------------------------------------------------------
// Exported ABI
// ---------------------------------------------------------------------------

//export invokeMethod
func invokeMethod(callback unsafe.Pointer, paramsChar *C.char) {
	params := takeCString(paramsChar)
	defer releaseObject(callback)
	core.InvokeMethod(params, func(result []byte) {
		invokeResult(callback, string(result))
	})
}

//export quickSetup
func quickSetup(callback unsafe.Pointer, initParamsChar *C.char, setupParamsChar *C.char) {
	initParams := takeCString(initParamsChar)
	setupParams := takeCString(setupParamsChar)
	go func() {
		defer releaseObject(callback)
		defer func() {
			if r := recover(); r != nil {
				invokeResult(callback, fmt.Sprintf("internal panic: %v", r))
			}
		}()
		core.QuickSetup(initParams, setupParams, func(message string) {
			invokeResult(callback, message)
		})
	}()
}

// startTunOptions mirrors the JSON the Swift tunnel configuration builds. Only
// the fields the core's TUN start actually reads are forwarded.
type startTunOptions struct {
	Stack                string `json:"stack"`
	Address              string `json:"address"`
	DNS                  string `json:"dns"`
	MTU                  int    `json:"mtu"`
	CongestionController string `json:"congestionController"`
}

type tunStartOptions struct {
	MTU                  uint32 `json:"mtu"`
	CongestionController string `json:"congestion-controller"`
}

//export startTUN
func startTUN(callback unsafe.Pointer, fd C.int, optionsChar *C.char) C.int {
	raw := takeCString(optionsChar)
	var options startTunOptions
	if err := json.Unmarshal([]byte(raw), &options); err != nil {
		logError("startTUN: invalid options: %v", err)
		return 0
	}
	tunOptions, err := json.Marshal(tunStartOptions{
		MTU:                  uint32(options.MTU),
		CongestionController: options.CongestionController,
	})
	if err != nil {
		logError("startTUN: marshal options: %v", err)
		return 0
	}
	started := core.StartTun(
		tunCallbacks{handle: callback},
		int(fd),
		options.Stack,
		options.Address,
		options.DNS,
		string(tunOptions),
	)
	if !started {
		logError("startTUN: core refused the descriptor (fd=%d stack=%s)", int(fd), options.Stack)
		return 0
	}
	return 1
}

//export stopTun
func stopTun() {
	core.StopTun()
}

var (
	eventCallbackLock sync.Mutex
	eventCallback     unsafe.Pointer
)

//export setEventListener
func setEventListener(callback unsafe.Pointer) {
	eventCallbackLock.Lock()
	previous := eventCallback
	eventCallback = callback
	eventCallbackLock.Unlock()
	if previous != nil {
		releaseObject(previous)
	}
	if callback == nil {
		core.SetEventListener(nil)
		return
	}
	core.SetEventListener(func(data []byte) {
		eventCallbackLock.Lock()
		current := eventCallback
		eventCallbackLock.Unlock()
		invokeResult(current, string(data))
	})
}

//export forceGC
func forceGC() {
	core.ForceGC()
}

//export getTraffic
func getTraffic(onlyStatisticsProxy C.int) *C.char {
	return C.CString(core.GetTraffic(onlyStatisticsProxy != 0))
}

//export getTotalTraffic
func getTotalTraffic(onlyStatisticsProxy C.int) *C.char {
	return C.CString(core.GetTotalTraffic(onlyStatisticsProxy != 0))
}

// ---------------------------------------------------------------------------
// Memory governor
//
// A packet-tunnel extension is jetsam-capped: iOS 15+ kills it at 50MB of
// phys_footprint with an EXC_RESOURCE "ActiveHard 50 MB" report, and the app
// never sees it. debug.SetMemoryLimit is only a GC hint, so the governor
// watches the same figure jetsam watches and forces a collection before the
// kernel does it for us.
// ---------------------------------------------------------------------------

var (
	governorOnce      sync.Once
	memoryCeiling     atomic.Uint64
	governorStopped   atomic.Bool
	lowmemBuild       bool
	defaultCeiling    uint64
	defaultGCPercent  int32 = 50
)

//export setMemoryLimit
func setMemoryLimit(ceilingBytes C.longlong) {
	value := int64(ceilingBytes)
	if value <= 0 {
		// The lowmem archive carries its own ceiling; the app-side archive
		// only gets one if Swift asks for it.
		value = int64(defaultCeiling)
	}
	if value <= 0 {
		return
	}
	ceiling := uint64(value)
	memoryCeiling.Store(ceiling)
	goHeadroom := ceiling * 6 / 10
	debug.SetMemoryLimit(int64(goHeadroom))
	debug.SetGCPercent(int(defaultGCPercent))
	governorOnce.Do(func() {
		go governor()
	})
	logInfo(fmt.Sprintf("memory governor: lowmem=%v ceiling=%dMiB goLimit=%dMiB", lowmemBuild, ceiling>>20, goHeadroom>>20))
}

func governor() {
	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()
	warned := false
	for !governorStopped.Load() {
		<-ticker.C
		ceiling := memoryCeiling.Load()
		if ceiling == 0 {
			continue
		}
		footprint := uint64(C.phys_footprint())
		switch {
		case footprint > ceiling*85/100:
			core.ForceGC()
			logError("memory: footprint=%dMiB over 85%% of %dMiB, forced GC", footprint>>20, ceiling>>20)
		case footprint > ceiling*70/100:
			if !warned {
				logError("memory: footprint=%dMiB over 70%% of %dMiB", footprint>>20, ceiling>>20)
				warned = true
			}
			core.ForceGC()
		default:
			warned = false
		}
	}
}

//export stopMemoryGovernor
func stopMemoryGovernor() {
	governorStopped.Store(true)
}
