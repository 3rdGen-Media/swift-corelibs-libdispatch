//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2016 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import CDispatch

public struct DispatchData : RandomAccessCollection {
	public typealias Iterator = DispatchDataIterator
	public typealias Index = Int
	public typealias Indices = DefaultRandomAccessIndices<DispatchData>

	public static let empty: DispatchData = DispatchData(data: _swift_dispatch_data_empty())

	public enum Deallocator {
		/// Use `free`
		case free

		/// Use `munmap`
		case unmap

		/// A custom deallocator
		// FIXME: Want @convention(block) here to minimize the overhead of
		//        doing the conversion (once per custom enum instance instead
		//        of once per call to DispatchData.init using the enum instance).
		//        However, adding the annotation here results in Data.o containing
		//        a reference to _TMBO (opaque metadata for Builtin.UnknownObject)
		//        which is only made available on platforms with Objective-C.
		case custom(DispatchQueue?, () -> Void)

		fileprivate var _deallocator: (DispatchQueue?, @convention(block) () -> Void) {
			switch self {
			case .free: return (nil, _dispatch_data_destructor_free())
			case .unmap: return (nil, _dispatch_data_destructor_munmap())
			case .custom(let q, let b): return (q, b)
			}
		}
	}

	internal var __wrapped: __DispatchData

	/// Initialize a `Data` with copied memory content.
	///
	/// - parameter bytes: A pointer to the memory. It will be copied.
	/// - parameter count: The number of bytes to copy.
	public init(bytes buffer: UnsafeBufferPointer<UInt8>) {
		let d = dispatch_data_create(buffer.baseAddress!, buffer.count, nil, _dispatch_data_destructor_default())
		self.init(data: d)
	}

	/// Initialize a `Data` without copying the bytes.
	///
	/// - parameter bytes: A buffer pointer containing the data.
	/// - parameter deallocator: Specifies the mechanism to free the indicated buffer.
	public init(bytesNoCopy bytes: UnsafeBufferPointer<UInt8>, deallocator: Deallocator = .free) {
		let (q, b) = deallocator._deallocator
		let d = dispatch_data_create(bytes.baseAddress!, bytes.count, q?.__wrapped, b)
		self.init(data: d)
	}

	internal init(data: dispatch_data_t) {
		__wrapped = __DispatchData(data: data, owned: true)
	}

	internal init(borrowedData: dispatch_data_t) {
		__wrapped = __DispatchData(data: borrowedData, owned: false)
	}

	public var count: Int {
		return CDispatch.dispatch_data_get_size(__wrapped.__wrapped)
	}

	public func withUnsafeBytes<Result, ContentType>(
		body: (UnsafePointer<ContentType>) throws -> Result) rethrows -> Result
	{
		var ptr: UnsafeRawPointer? = nil
		var size = 0
		let data = CDispatch.dispatch_data_create_map(__wrapped.__wrapped, &ptr, &size)
		let contentPtr = ptr!.bindMemory(
			to: ContentType.self, capacity: size / MemoryLayout<ContentType>.stride)
		defer { _fixLifetime(data) }
		return try body(contentPtr)
	}

	public func enumerateBytes(
		block: (_ buffer: UnsafeBufferPointer<UInt8>, _ byteIndex: Int, _ stop: inout Bool) -> Void) 
	{
		// FIXME: When SR-2313 (withoutActuallyEscaping) is implemented, use it to replace unsafeBitCast
		let nonEscapingBlock = unsafeBitCast(block, to: _enumerateBytesBlock.self)
		_ = CDispatch.dispatch_data_apply(__wrapped.__wrapped) { (_, offset: Int, ptr: UnsafeRawPointer, size: Int) in
			let bytePtr = ptr.bindMemory(to: UInt8.self, capacity: size)
			let bp = UnsafeBufferPointer(start: bytePtr, count: size)
			var stop = false
			nonEscapingBlock(bp, offset, &stop)
			return !stop
		}
	}

	/// Append bytes to the data.
	///
	/// - parameter bytes: A pointer to the bytes to copy in to the data.
	/// - parameter count: The number of bytes to copy.
	public mutating func append(_ bytes: UnsafePointer<UInt8>, count: Int) {
		let data = dispatch_data_create(bytes, count, nil, _dispatch_data_destructor_default())
		self.append(DispatchData(data: data))
	}

	/// Append data to the data.
	///
	/// - parameter data: The data to append to this data.
	public mutating func append(_ other: DispatchData) {
		let data = CDispatch.dispatch_data_create_concat(__wrapped.__wrapped, other.__wrapped.__wrapped)
		__wrapped = __DispatchData(data: data, owned: true)
	}

	/// Append a buffer of bytes to the data.
	///
	/// - parameter buffer: The buffer of bytes to append. The size is calculated from `SourceType` and `buffer.count`.
	public mutating func append<SourceType>(_ buffer : UnsafeBufferPointer<SourceType>) {
		let count = buffer.count * MemoryLayout<SourceType>.stride;
		buffer.baseAddress?.withMemoryRebound(to: UInt8.self, capacity: count) {
			self.append($0, count: count)
		}
	}

	private func _copyBytesHelper(to pointer: UnsafeMutablePointer<UInt8>, from range: CountableRange<Index>) {
		var copiedCount = 0
		_ = CDispatch.dispatch_data_apply(__wrapped.__wrapped) { (data: dispatch_data_t, offset: Int, ptr: UnsafeRawPointer, size: Int) in
			let limit = Swift.min((range.endIndex - range.startIndex) - copiedCount, size)
			memcpy(pointer + copiedCount, ptr, limit)
			copiedCount += limit
			return copiedCount < (range.endIndex - range.startIndex)
		}
	}

	/// Copy the contents of the data to a pointer.
	///
	/// - parameter pointer: A pointer to the buffer you wish to copy the bytes into.
	/// - parameter count: The number of bytes to copy.
	/// - warning: This method does not verify that the contents at pointer have enough space to hold `count` bytes.
	public func copyBytes(to pointer: UnsafeMutablePointer<UInt8>, count: Int) {
		_copyBytesHelper(to: pointer, from: 0..<count)
	}
		
	/// Copy a subset of the contents of the data to a pointer.
	///
	/// - parameter pointer: A pointer to the buffer you wish to copy the bytes into.
	/// - parameter range: The range in the `Data` to copy.
	/// - warning: This method does not verify that the contents at pointer have enough space to hold the required number of bytes.
	public func copyBytes(to pointer: UnsafeMutablePointer<UInt8>, from range: CountableRange<Index>) {
		_copyBytesHelper(to: pointer, from: range)
	}
	
	/// Copy the contents of the data into a buffer.
	///
	/// This function copies the bytes in `range` from the data into the buffer. If the count of the `range` is greater than `MemoryLayout<DestinationType>.stride * buffer.count` then the first N bytes will be copied into the buffer.
	/// - precondition: The range must be within the bounds of the data. Otherwise `fatalError` is called.
	/// - parameter buffer: A buffer to copy the data into.
	/// - parameter range: A range in the data to copy into the buffer. If the range is empty, this function will return 0 without copying anything. If the range is nil, as much data as will fit into `buffer` is copied.
	/// - returns: Number of bytes copied into the destination buffer.
	public func copyBytes<DestinationType>(to buffer: UnsafeMutableBufferPointer<DestinationType>, from range: CountableRange<Index>? = nil) -> Int {
		let cnt = count
		guard cnt > 0 else { return 0 }
		
		let copyRange : CountableRange<Index>
		if let r = range {
			guard !r.isEmpty else { return 0 }
			precondition(r.startIndex >= 0)
			precondition(r.startIndex < cnt, "The range is outside the bounds of the data")
			
			precondition(r.endIndex >= 0)
			precondition(r.endIndex <= cnt, "The range is outside the bounds of the data")
			
			copyRange = r.startIndex..<(r.startIndex + Swift.min(buffer.count * MemoryLayout<DestinationType>.stride, r.count))
		} else {
			copyRange = 0..<Swift.min(buffer.count * MemoryLayout<DestinationType>.stride, cnt)
		}
		
		guard !copyRange.isEmpty else { return 0 }
		
		let bufferCapacity = buffer.count * MemoryLayout<DestinationType>.stride
		buffer.baseAddress?.withMemoryRebound(to: UInt8.self, capacity: bufferCapacity) {
			_copyBytesHelper(to: $0, from: copyRange)
		}
		return copyRange.count
	}

	/// Sets or returns the byte at the specified index.
	public subscript(index: Index) -> UInt8 {
		var offset = 0
		let subdata = CDispatch.dispatch_data_copy_region(__wrapped.__wrapped, index, &offset)

		var ptr: UnsafeRawPointer? = nil
		var size = 0
		let map = CDispatch.dispatch_data_create_map(subdata, &ptr, &size)
		defer { _fixLifetime(map) }

		return ptr!.load(fromByteOffset: index - offset, as: UInt8.self)
	}

	public subscript(bounds: Range<Int>) -> RandomAccessSlice<DispatchData> {
		return RandomAccessSlice(base: self, bounds: bounds)
	}

	/// Return a new copy of the data in a specified range.
	///
	/// - parameter range: The range to copy.
	public func subdata(in range: CountableRange<Index>) -> DispatchData {
		let subrange = CDispatch.dispatch_data_create_subrange(
			__wrapped.__wrapped, range.startIndex, range.endIndex - range.startIndex)
		return DispatchData(data: subrange)
	}

	public func region(location: Int) -> (data: DispatchData, offset: Int) {
		var offset: Int = 0
		let data = CDispatch.dispatch_data_copy_region(__wrapped.__wrapped, location, &offset)
		return (DispatchData(data: data), offset)
	}

	public var startIndex: Index {
		return 0
	}

	public var endIndex: Index {
		return count
	}

	public func index(before i: Index) -> Index {
		return i - 1
	}

	public func index(after i: Index) -> Index {
		return i + 1
	}

	/// An iterator over the contents of the data.
	///
	/// The iterator will increment byte-by-byte.
	public func makeIterator() -> DispatchData.Iterator {
		return DispatchDataIterator(_data: self)
	}
}

public struct DispatchDataIterator : IteratorProtocol, Sequence {

	/// Create an iterator over the given DisaptchData
	public init(_data: DispatchData) {
		var ptr: UnsafeRawPointer?
		self._count = 0
		self._data = __DispatchData(data: CDispatch.dispatch_data_create_map(_data.__wrapped.__wrapped, &ptr, &self._count), owned: true)
		self._ptr = ptr
		self._position = _data.startIndex

		// The only time we expect a 'nil' pointer is when the data is empty.
		assert(self._ptr != nil || self._count == self._position)
	}

	/// Advance to the next element and return it, or `nil` if no next
	/// element exists.
	public mutating func next() -> DispatchData._Element? {
		if _position == _count { return nil }
		let element = _ptr.load(fromByteOffset: _position, as: UInt8.self)
		_position = _position + 1
		return element
	}

	internal let _data: __DispatchData
	internal var _ptr: UnsafeRawPointer!
	internal var _count: Int
	internal var _position: DispatchData.Index
}

typealias _enumerateBytesBlock = (_ buffer: UnsafeBufferPointer<UInt8>, _ byteIndex: Int, _ stop: inout Bool) -> Void

@_silgen_name("_swift_dispatch_data_empty")
internal func _swift_dispatch_data_empty() -> dispatch_data_t

@_silgen_name("_swift_dispatch_data_destructor_free")
internal func _dispatch_data_destructor_free() -> _DispatchBlock

@_silgen_name("_swift_dispatch_data_destructor_munmap")
internal func _dispatch_data_destructor_munmap() -> _DispatchBlock

@_silgen_name("_swift_dispatch_data_destructor_default")
internal func _dispatch_data_destructor_default() -> _DispatchBlock
