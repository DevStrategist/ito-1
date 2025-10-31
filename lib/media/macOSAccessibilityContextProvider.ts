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

      console.log(
        '[MacOSAccessibilityContextProvider] Process started successfully.',
      )
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
      console.log('[MacOSAccessibilityContextProvider] Sending command:', commandStr.trim())
      this.#process.stdin.write(commandStr)
      console.log('[MacOSAccessibilityContextProvider] Command sent successfully')
    } catch (error) {
      log.error(
        '[MacOSAccessibilityContextProvider] Error sending command:',
        error,
      )
    }
  }

  #onData(data: Buffer): void {
    console.log('[MacOSAccessibilityContextProvider] Received stdout data:', data.toString().trim())
    const lines = data.toString().trim().split('\n')

    for (const line of lines) {
      if (!line.trim()) continue

      try {
        const response: CursorContextResponse = JSON.parse(line)

        // Handle context result or error
        if (
          response.requestId &&
          this.#pendingRequests.has(response.requestId)
        ) {
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
    const message = data.toString()
    console.log('[MacOSAccessibilityContextProvider] stderr:', message)
    log.error('[MacOSAccessibilityContextProvider] stderr:', message)
  }

  #onClose(code: number | null, signal: string | null): void {
    log.warn(
      `[MacOSAccessibilityContextProvider] Process exited with code: ${code}, signal: ${signal}`,
    )

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
}

// Export singleton instance
export const macOSAccessibilityContextProvider =
  new MacOSAccessibilityContextProvider()
