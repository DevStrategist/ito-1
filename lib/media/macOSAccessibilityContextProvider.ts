/**
 * macOS Accessibility Context Provider Implementation
 *
 * Manages a long-running native process that retrieves cursor context
 * using macOS NSAccessibility/AXUIElement APIs.
 */

import { spawn } from 'child_process'
import type { ChildProcess } from 'child_process'
import { platform, arch } from 'os'
import { getNativeBinaryPath } from './native-interface'
import log from 'electron-log'
import { EventEmitter } from 'events'
import type { IAccessibilityContextProvider } from './accessibilityContextProvider'
import type {
  CursorContextOptions,
  CursorContextResult,
} from '../types/cursorContext'

const NATIVE_MODULE_NAME = 'cursor-context'
const DEFAULT_TIMEOUT = 5000 // 5 seconds
const HEARTBEAT_CHECK_INTERVAL = 5000 // Check every 5 seconds
const HEARTBEAT_TIMEOUT = 15000 // 15 seconds without heartbeat triggers restart

interface CursorContextCommand {
  command: 'get-context'
  options?: CursorContextOptions
  requestId: string
}

interface CursorContextResponse {
  type: 'context-result' | 'error' | 'heartbeat_ping'
  requestId?: string
  result?: CursorContextResult
  error?: string
  id?: string
  timestamp?: string
}

interface PendingRequest {
  resolve: (value: CursorContextResult) => void
  reject: (reason: Error) => void
  timeoutId?: NodeJS.Timeout
}

export class MacOSAccessibilityContextProvider
  extends EventEmitter
  implements IAccessibilityContextProvider
{
  #process: ChildProcess | null = null
  #pendingRequests = new Map<string, PendingRequest>()
  #requestIdCounter = 0
  #lastHeartbeatReceived = Date.now()
  #heartbeatCheckTimer: NodeJS.Timeout | null = null

  constructor() {
    super()
  }

  public initialize(): void {
    if (this.#process) {
      log.warn(
        '[MacOSAccessibilityContextProvider] Process already running, skipping initialization.',
      )
      return
    }

    const binaryPath = getNativeBinaryPath(NATIVE_MODULE_NAME)
    if (!binaryPath) {
      const error = new Error(
        `Cannot determine ${NATIVE_MODULE_NAME} binary path for platform ${platform()} and arch ${arch()}`,
      )
      log.error('[MacOSAccessibilityContextProvider]', error.message)
      this.emit('error', error)
      throw error
    }

    console.log(
      `[MacOSAccessibilityContextProvider] Spawning process at: ${binaryPath}`,
    )

    try {
      this.#process = spawn(binaryPath, [], {
        stdio: ['pipe', 'pipe', 'pipe'],
      })

      if (!this.#process) {
        throw new Error('Failed to spawn process')
      }

      this.#process.stdout?.on('data', this.#onData.bind(this))
      this.#process.stderr?.on('data', this.#onStdErr.bind(this))
      this.#process.on('close', this.#onClose.bind(this))
      this.#process.on('error', this.#onError.bind(this))

      this.#startHeartbeatMonitoring()

      console.log('[MacOSAccessibilityContextProvider] Process started successfully.')
      this.emit('ready')
    } catch (err) {
      log.error(
        '[MacOSAccessibilityContextProvider] Error spawning process:',
        err,
      )
      this.#process = null
      this.emit('error', err)
      throw err
    }
  }

  public shutdown(): void {
    if (this.#process) {
      console.log('[MacOSAccessibilityContextProvider] Shutting down process.')

      this.#stopHeartbeatMonitoring()

      this.#process.kill()
      this.#process = null

      // Reject all pending requests
      this.#pendingRequests.forEach(({ reject, timeoutId }) => {
        if (timeoutId) {
          clearTimeout(timeoutId)
        }
        reject(new Error('Provider shutdown'))
      })
      this.#pendingRequests.clear()

      this.emit('exit', 0, null)
    }
  }

  public isRunning(): boolean {
    return this.#process !== null && !this.#process.killed
  }

  public async getCursorContext(
    options?: CursorContextOptions,
  ): Promise<CursorContextResult> {
    if (!this.#process) {
      throw new Error('Process not running. Call initialize() first.')
    }

    return new Promise((resolve, reject) => {
      const requestId = `req_${++this.#requestIdCounter}_${Date.now()}`
      const timeout = options?.timeout || DEFAULT_TIMEOUT

      const timeoutId = setTimeout(() => {
        if (this.#pendingRequests.has(requestId)) {
          this.#pendingRequests.delete(requestId)
          reject(new Error(`Request timed out after ${timeout}ms`))
        }
      }, timeout)

      this.#pendingRequests.set(requestId, { resolve, reject, timeoutId })

      const command: CursorContextCommand = {
        command: 'get-context',
        options,
        requestId,
      }

      this.#sendCommand(command)
    })
  }

  #sendCommand(command: CursorContextCommand): void {
    if (!this.#process || !this.#process.stdin) {
      log.error(
        '[MacOSAccessibilityContextProvider] Cannot send command, process not running',
      )
      return
    }

    try {
      const commandStr = JSON.stringify(command) + '\n'
      this.#process.stdin.write(commandStr)
    } catch (error) {
      log.error('[MacOSAccessibilityContextProvider] Error sending command:', error)
    }
  }

  #onData(data: Buffer): void {
    const lines = data.toString().trim().split('\n')

    for (const line of lines) {
      if (!line.trim()) continue

      try {
        const response: CursorContextResponse = JSON.parse(line)

        // Handle heartbeat
        if (response.type === 'heartbeat_ping') {
          this.#lastHeartbeatReceived = Date.now()
          this.emit('heartbeat', response.timestamp || new Date().toISOString())
          continue
        }

        // Handle context result or error
        if (response.requestId && this.#pendingRequests.has(response.requestId)) {
          const { resolve, reject, timeoutId } = this.#pendingRequests.get(
            response.requestId,
          )!
          this.#pendingRequests.delete(response.requestId)

          if (timeoutId) {
            clearTimeout(timeoutId)
          }

          if (response.type === 'error') {
            reject(new Error(response.error || 'Unknown error'))
          } else if (response.type === 'context-result' && response.result) {
            resolve(response.result)
          } else {
            reject(new Error('Invalid response format'))
          }
        } else if (response.requestId) {
          log.warn(
            '[MacOSAccessibilityContextProvider] Received response for unknown request:',
            response.requestId,
          )
        }
      } catch (error) {
        log.error(
          '[MacOSAccessibilityContextProvider] Error parsing response:',
          error,
          'Raw data:',
          line,
        )
      }
    }
  }

  #onStdErr(data: Buffer): void {
    log.error('[MacOSAccessibilityContextProvider] stderr:', data.toString())
  }

  #onClose(code: number | null, signal: string | null): void {
    log.warn(
      `[MacOSAccessibilityContextProvider] Process exited with code: ${code}, signal: ${signal}`,
    )

    this.#stopHeartbeatMonitoring()
    this.#process = null

    // Reject all pending requests
    this.#pendingRequests.forEach(({ reject, timeoutId }) => {
      if (timeoutId) {
        clearTimeout(timeoutId)
      }
      reject(new Error(`Process exited with code ${code}`))
    })
    this.#pendingRequests.clear()

    this.emit('exit', code, signal)
  }

  #onError(error: Error): void {
    log.error('[MacOSAccessibilityContextProvider] Process error:', error)
    this.emit('error', error)
  }

  #startHeartbeatMonitoring(): void {
    this.#lastHeartbeatReceived = Date.now()

    this.#heartbeatCheckTimer = setInterval(() => {
      const timeSinceLastHeartbeat = Date.now() - this.#lastHeartbeatReceived

      if (timeSinceLastHeartbeat > HEARTBEAT_TIMEOUT) {
        log.error(
          `[MacOSAccessibilityContextProvider] No heartbeat for ${timeSinceLastHeartbeat}ms, process may be unresponsive`,
        )
        this.emit('error', new Error('Heartbeat timeout'))
        // Could implement auto-restart here if needed
      }
    }, HEARTBEAT_CHECK_INTERVAL)
  }

  #stopHeartbeatMonitoring(): void {
    if (this.#heartbeatCheckTimer) {
      clearInterval(this.#heartbeatCheckTimer)
      this.#heartbeatCheckTimer = null
    }
  }
}

// Export singleton instance
export const macOSAccessibilityContextProvider = new MacOSAccessibilityContextProvider()
