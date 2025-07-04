//
//  TokenBucket.swift
//  
//
//  Created by Adolfo Vera Blasco on 15/6/24.
//

import OpenCombine
import Foundation
@preconcurrency import Redis
import Vapor

/**
 For example, the token bucket capacity is 4 above. 
 Every second, the refiller adds 1 token to the bucket.
 Extra tokens will overflow once the bucket is full.
 
 • We take 1 token out for each request and if there are enough tokens, then the request is processed.
 • The request is dropped if there aren't enough tokens.
*/
public final class TokenBucket {
	private let configuration: TokenBucketConfiguration
	public let storage: Application.Redis
	public let logging: Logger?
	
	private var cancellable: AnyCancellable?
	private var keys = Set<String>()
	private let lock = Lock()
	
	public init(configuration: () -> TokenBucketConfiguration, storage: StorageAction, logging: LoggerAction? = nil) {
		self.configuration = configuration()
		self.storage = storage()
		self.logging = logging?()
		
		self.cancellable = startWindow(havingDuration: self.configuration.refillTimeInterval.inSeconds,
									   performing: resetWindow)
	}
	
	deinit {
		cancellable?.cancel()
	}
	
	private func preparaStorageFor(key: RedisKey) async {
		do {
			try await storage.set(key, to: configuration.bucketSize).get()
		} catch let redisError {
			logging?.error("🚨 Problem setting key \(key.rawValue) to value \(configuration.bucketSize)")
		}
	}
}

extension TokenBucket: WindowBasedAlgorithm {
	public func checkRequest(_ request: Request) async throws {
		guard let requestKey = try? valueFor(field: configuration.appliedField, in: request, inside: configuration.scope) else {
			return
		}
		
		lock.withLock {
			keys.insert(requestKey)
		}
		let redisKey = RedisKey(requestKey)
		
		let keyExists = try await storage.exists(redisKey).get()
		
		if keyExists == 0 {
			await preparaStorageFor(key: redisKey)
		}
		
		// 1. New request, remove one token from the bucket
		let bucketItemsCount = try await storage.decrement(redisKey).get()
		// 2. If buckes is empty, throw an error
		if bucketItemsCount < 0 {
			logging?.warning("🚨 Rate limit exceeded for key \(redisKey.rawValue). Rejecting request.")
			throw Abort(.tooManyRequests)
		}
	}
	
	public func resetWindow() throws {
		let currentKeys = lock.withLock {
			self.keys
		}

		currentKeys.forEach { key in
			Task(priority: .userInitiated) {
				let redisKey = RedisKey(key)
			
				let respValue = try await storage.get(redisKey).get()
			
				var newRefillSize = 0
				
				if let currentBucketSize = respValue.int {
					switch currentBucketSize {
						case ...0:
							newRefillSize -= currentBucketSize
						case configuration.bucketSize...:
							newRefillSize = configuration.bucketSize - currentBucketSize
						default:
							newRefillSize	= configuration.refillTokenRate
					}
				}
					
				try await storage.increment(redisKey, by: newRefillSize).get()
			}
		}
	}
}

extension TokenBucket {
	enum Constants {
		static let KeyName = "TokenBucket-Key"
	}
}
