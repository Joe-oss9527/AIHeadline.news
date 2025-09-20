/// <reference types="@cloudflare/workers-types" />

interface Env {
  GA4_SERVICE_KEY: string            // Secret: Full service account JSON
  GA4_PROPERTY_ID: string            // GA4 property ID (numeric)
  GA_START_DATE?: string             // Optional: Start date for stats (YYYY-MM-DD)
  ASSETS: Fetcher                    // Static assets handler
  NODE_ENV?: string                  // Environment: 'production' | 'development'
}

// TypeScript interfaces for GA4 API responses
interface GA4MetricValue {
  value?: string;
}

interface GA4Row {
  metricValues?: GA4MetricValue[];
  dimensionValues?: Array<{
    value?: string;
    oneValue?: string;
  }>;
}

// Property quota information
interface PropertyQuota {
  tokensConsumed?: number;
  tokensRemaining?: number;
  concurrentRequests?: number;
  serverErrorsPerProjectPerPropertyPerHour?: number;
  potentiallyThresholdedRequestsPerHour?: number;
}

interface GA4Response {
  rows?: GA4Row[];
  totals?: GA4Row[];
  rowCount?: number;
  metricHeaders?: Array<{
    name: string;
    type: string;
  }>;
  propertyQuota?: PropertyQuota;  // Quota information when returnPropertyQuota is true
}

interface GA4ErrorResponse {
  error: {
    code: number;
    message: string;
    status: string;
    details?: unknown[];
  };
}

// Type guard for GA4 error responses
function isGA4Error(response: unknown): response is GA4ErrorResponse {
  return (
    typeof response === 'object' &&
    response !== null &&
    'error' in response &&
    typeof (response as any).error === 'object'
  );
}

// Validate GA4 response structure
function validateGA4Response(data: unknown): data is GA4Response {
  if (!data || typeof data !== 'object') {
    return false;
  }
  
  const d = data as any;
  
  // Must have either rows or totals
  if (!Array.isArray(d.rows) && !Array.isArray(d.totals)) {
    return false;
  }
  
  // Validate rows structure if present
  if (d.rows && Array.isArray(d.rows)) {
    for (const row of d.rows) {
      if (!row || typeof row !== 'object') {
        return false;
      }
      
      // Check metricValues
      if (!Array.isArray(row.metricValues)) {
        return false;
      }
      
      for (const mv of row.metricValues) {
        if (!mv || typeof mv !== 'object' || typeof mv.value !== 'string') {
          return false;
        }
      }
    }
  }
  
  // Validate totals structure if present
  if (d.totals && Array.isArray(d.totals)) {
    for (const total of d.totals) {
      if (!total || !Array.isArray(total.metricValues)) {
        return false;
      }
    }
  }
  
  return true;
}

// Custom error class for quota exceeded
class QuotaExceededError extends Error {
  constructor(
    public remaining: number = 0,
    public resetTime?: string
  ) {
    super(`GA4 API quota exceeded. Remaining tokens: ${remaining}`);
    this.name = 'QuotaExceededError';
  }
}

// Check if error is quota-related
function isQuotaError(error: unknown): boolean {
  if (error instanceof Response && error.status === 429) {
    return true;
  }
  if (error instanceof Error) {
    const message = error.message.toLowerCase();
    return message.includes('quota') || 
           message.includes('rate limit') ||
           message.includes('too many requests');
  }
  return false;
}

// Safe number parsing with validation
function parseMetricValue(value: string | undefined): number {
  if (!value) return 0;
  const num = parseInt(value, 10);
  if (isNaN(num) || num < 0) {
    console.warn(`Invalid metric value: ${value}, defaulting to 0`);
    return 0;
  }
  return num;
}

// Find aggregated value in GA4 response (for TOTAL aggregation)
function findAggregatedValue(
  ga4Data: GA4Response,
  aggregationType: string = 'TOTAL'
): string | undefined {
  // When using metricAggregations, GA4 returns aggregated values in special rows
  // with dimension values like "RESERVED_TOTAL"
  if (!ga4Data.rows) return undefined;
  
  // Look for reserved aggregation rows
  for (const row of ga4Data.rows) {
    // Check if this is an aggregation row
    // Note: GA4 might return aggregated values in different formats
    if (row.dimensionValues?.[0]?.value?.includes(`RESERVED_${aggregationType}`)) {
      return row.metricValues?.[0]?.value;
    }
  }
  
  // If no reserved row found, check for totals (older API behavior)
  return ga4Data.totals?.[0]?.metricValues?.[0]?.value;
}

// Calculate dynamic cache control based on quota
function calculateCacheControl(
  metric: string,
  quota?: PropertyQuota
): string {
  const baseRealtimeCache = CONFIG.CACHE.STATS_REALTIME_TTL;
  const baseTotalCache = CONFIG.CACHE.STATS_TOTAL_TTL;
  
  // If quota is low, extend cache duration to reduce API calls
  if (quota?.tokensRemaining) {
    if (quota.tokensRemaining < 100) {
      // Critical: 5x cache duration
      const multiplier = 5;
      return metric === 'activeUsers'
        ? `s-maxage=${baseRealtimeCache * multiplier}, stale-while-revalidate=${CONFIG.CACHE.STALE_WHILE_REVALIDATE.REALTIME * 2}`
        : `s-maxage=${baseTotalCache * multiplier}, stale-while-revalidate=${CONFIG.CACHE.STALE_WHILE_REVALIDATE.TOTAL * 2}`;
    } else if (quota.tokensRemaining < 200) {
      // Warning: 2x cache duration
      const multiplier = 2;
      return metric === 'activeUsers'
        ? `s-maxage=${baseRealtimeCache * multiplier}, stale-while-revalidate=${CONFIG.CACHE.STALE_WHILE_REVALIDATE.REALTIME * 1.5}`
        : `s-maxage=${baseTotalCache * multiplier}, stale-while-revalidate=${CONFIG.CACHE.STALE_WHILE_REVALIDATE.TOTAL * 1.5}`;
    }
  }
  
  // Normal cache duration
  return metric === 'activeUsers'
    ? `s-maxage=${baseRealtimeCache}, stale-while-revalidate=${CONFIG.CACHE.STALE_WHILE_REVALIDATE.REALTIME}`
    : `s-maxage=${baseTotalCache}, stale-while-revalidate=${CONFIG.CACHE.STALE_WHILE_REVALIDATE.TOTAL}`;
}

// Retry configuration
interface RetryOptions {
  maxRetries?: number;
  initialDelay?: number;
  maxDelay?: number;
  shouldRetry?: (error: unknown, attempt: number) => boolean;
}

// Default retry configuration
const DEFAULT_RETRY_OPTIONS: Required<RetryOptions> = {
  maxRetries: 3,
  initialDelay: 1000,
  maxDelay: 10000,
  shouldRetry: (error: unknown, attempt: number) => {
    // Always check attempt limit first
    if (attempt >= 3) {
      return false;
    }
    
    // Retry on network errors (with limit)
    if (error instanceof Error) {
      const message = error.message.toLowerCase();
      if (message.includes('fetch failed') || 
          message.includes('network') ||
          message.includes('timeout')) {
        return true; // Will be limited by attempt check above
      }
    }
    
    // Retry on specific HTTP status codes
    if (error instanceof Response) {
      return error.status >= 500 || error.status === 429;
    }
    
    return false; // Default: don't retry
  }
};

// Exponential backoff with jitter
function calculateDelay(attempt: number, initialDelay: number, maxDelay: number): number {
  const exponentialDelay = initialDelay * Math.pow(2, attempt);
  const jitter = Math.random() * 0.3 * exponentialDelay; // 30% jitter
  return Math.min(exponentialDelay + jitter, maxDelay);
}

// Calculate delay for quota errors (longer backoff)
function calculateQuotaDelay(attempt: number, retryAfter?: string): number {
  // If server provides Retry-After header, use it
  if (retryAfter) {
    const retryAfterMs = parseInt(retryAfter, 10) * 1000;
    if (!isNaN(retryAfterMs)) {
      return retryAfterMs;
    }
  }
  
  // Otherwise use aggressive backoff: 5s, 10s, 20s
  const baseDelay = 5000;
  return Math.min(baseDelay * Math.pow(2, attempt), 30000);
}

// Structured logging interface with generic type
interface LogContext<T = Record<string, unknown>> {
  timestamp: string;
  service: string;
  level: 'info' | 'warn' | 'error';
  message: string;
  metadata?: T;
}

// Structured logger with type safety
function log<T = Record<string, unknown>>(ctx: LogContext<T>): void {
  const logData = JSON.stringify(ctx);
  switch (ctx.level) {
    case 'error':
      console.error(logData);
      break;
    case 'warn':
      console.warn(logData);
      break;
    default:
      console.log(logData);
  }
}

// GA4 API metrics interface
interface GA4Metrics {
  endpoint: 'realtime' | 'core';
  metricType: string;
  responseTime: number;
  tokensConsumed?: number;
  tokensRemaining?: number;
  cacheHit: boolean;
  error?: string;
}

// Fetch with timeout capability
async function fetchWithTimeout(
  url: string,
  options: RequestInit = {},
  timeoutMs: number = 30000
): Promise<Response> {
  const controller = new AbortController();
  const timeoutId = setTimeout(() => controller.abort(), timeoutMs);
  
  try {
    const response = await fetch(url, {
      ...options,
      signal: controller.signal
    });
    clearTimeout(timeoutId);
    return response;
  } catch (error) {
    clearTimeout(timeoutId);
    if (error instanceof Error && error.name === 'AbortError') {
      throw new Error(`Request timeout after ${timeoutMs}ms`);
    }
    throw error;
  }
}

// Generic retry wrapper
async function withRetry<T>(
  fn: () => Promise<T>,
  options: RetryOptions = {}
): Promise<T> {
  const opts = { ...DEFAULT_RETRY_OPTIONS, ...options };
  let lastError: unknown;
  
  for (let attempt = 0; attempt <= opts.maxRetries; attempt++) {
    try {
      return await fn();
    } catch (error) {
      lastError = error;
      
      if (attempt === opts.maxRetries || !opts.shouldRetry(error, attempt)) {
        throw error;
      }
      
      // Use different delay calculation for quota errors
      const delay = isQuotaError(error)
        ? calculateQuotaDelay(attempt, error instanceof QuotaExceededError ? error.resetTime : undefined)
        : calculateDelay(attempt, opts.initialDelay, opts.maxDelay);
      
      console.warn(`Retry attempt ${attempt + 1}/${opts.maxRetries} after ${delay}ms`, {
        error: error instanceof Error ? error.message : String(error),
        isQuotaError: isQuotaError(error)
      });
      
      await new Promise(resolve => setTimeout(resolve, delay));
    }
  }
  
  throw lastError;
}

// Request deduplication with timestamp tracking
interface PendingRequest<T = any> {
  promise: Promise<T>;
  timestamp: number;
}

const pendingRequests = new Map<string, PendingRequest>();

// Cleanup old pending requests to prevent memory leak
function cleanupPendingRequests(): void {
  const now = Date.now();
  const timeout = 60000; // 1 minute timeout
  
  for (const [key, entry] of pendingRequests.entries()) {
    if (now - entry.timestamp > timeout) {
      pendingRequests.delete(key);
    }
  }
}

// Deduplication wrapper for concurrent identical requests
async function deduplicatedRequest<T>(
  key: string,
  requestFn: () => Promise<T>
): Promise<T> {
  // Cleanup old requests periodically (1% chance)
  if (Math.random() < 0.01) {
    cleanupPendingRequests();
  }
  
  // Check if there's already a pending request with the same key
  const existing = pendingRequests.get(key);
  if (existing && Date.now() - existing.timestamp < 60000) {
    console.log(`Deduplicating request: ${key}`);
    return existing.promise;
  }
  
  // Create new request and store with timestamp
  const promise = requestFn();
  const entry: PendingRequest<T> = {
    promise,
    timestamp: Date.now()
  };
  
  // Store the entry
  pendingRequests.set(key, entry);
  
  // Clean up after request completes
  promise.finally(() => {
    // Only delete if it's still the same entry
    const current = pendingRequests.get(key);
    if (current === entry) {
      pendingRequests.delete(key);
    }
  }).catch(() => {}); // Ignore errors in cleanup
  
  return promise;
}

interface TokenResponse {
  access_token: string;
  expires_in: number;
  token_type: string;
}

interface ServiceAccountKey {
  type: string;
  project_id: string;
  private_key_id: string;
  private_key: string;
  client_email: string;
  client_id: string;
  auth_uri: string;
  token_uri: string;
  auth_provider_x509_cert_url: string;
  client_x509_cert_url: string;
}

// Configuration constants
const CONFIG = {
  GA4: {
    API_BASE: 'https://analyticsdata.googleapis.com/v1beta',
    SCOPES: 'https://www.googleapis.com/auth/analytics.readonly',
    TOKEN_URL: 'https://oauth2.googleapis.com/token',
    DEFAULT_START_DATE: '2025-07-12'
  },
  CACHE: {
    TOKEN_KEY: 'ga4_access_token',
    TOKEN_TTL: 3300, // 55 minutes (token expires in 60)
    STATS_REALTIME_TTL: 5,
    STATS_TOTAL_TTL: 600,
    STALE_WHILE_REVALIDATE: {
      REALTIME: 30,
      TOTAL: 3600
    }
  },
  CORS: {
    MAX_AGE: 86400,
    ALLOWED_METHODS: 'GET, OPTIONS'
  }
} as const;

// Helper function to get CORS headers
function getCorsHeaders(req: Request, env: Env): HeadersInit {
  const allowedOrigins = env.NODE_ENV === 'production' 
    ? ['https://aiheadline.news']
    : ['https://aiheadline.news', 'http://localhost:1313'];
  
  const origin = req.headers.get('Origin');
  const corsOrigin = origin && allowedOrigins.includes(origin) ? origin : allowedOrigins[0];
  
  return {
    'Access-Control-Allow-Origin': corsOrigin,
    'Access-Control-Allow-Methods': CONFIG.CORS.ALLOWED_METHODS,
    'Access-Control-Max-Age': CONFIG.CORS.MAX_AGE.toString()
  };
}

export default {
  async fetch(req: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const url = new URL(req.url);

    // Validate required environment variables
    if (!env.GA4_SERVICE_KEY || !env.GA4_PROPERTY_ID) {
      console.error('Missing required environment variables');
      return new Response(JSON.stringify({ error: 'Service configuration error' }), { 
        status: 500,
        headers: { 'Content-Type': 'application/json' }
      });
    }

    // ------------------------------------------------------------------ stats
    if (url.pathname === '/stats') {
      try {
        // Validate request parameters
        const metricType = url.searchParams.get('t');
        if (metricType && metricType !== 'online' && metricType !== 'total') {
          return new Response(JSON.stringify({ error: 'Invalid metric type' }), { 
            status: 400,
            headers: { 'Content-Type': 'application/json' }
          });
        }
        
        // Create deduplication key based on metric type
        const deduplicationKey = `stats-${metricType || 'total'}`;
        
        // Wrap the entire stats logic in deduplication
        const result = await deduplicatedRequest(deduplicationKey, async () => {
          // Get access token (with caching)
          const token = await getAccessToken(env, ctx);

          const metric =
            metricType === 'online'
              ? 'activeUsers'
              : 'screenPageViews';

          const api = `${CONFIG.GA4.API_BASE}/properties/${env.GA4_PROPERTY_ID}:${metric === 'activeUsers' ? 'runRealtimeReport' : 'runReport'}`;

          const body =
            metric === 'activeUsers'
              ? { 
                  metrics: [{ name: 'activeUsers' }],
                  // No dimensions = total across all countries
                  returnPropertyQuota: true  // Monitor quota usage
                }
              : {
                  // Date range from site launch to today
                  dateRanges: [{ startDate: env.GA_START_DATE || CONFIG.GA4.DEFAULT_START_DATE, endDate: 'today' }],
                  metrics: [{ name: 'screenPageViews' }],
                  metricAggregations: ['TOTAL'], // Get aggregated sum
                  returnPropertyQuota: true  // Monitor quota usage
                };
                
          // Track performance
          const startTime = performance.now();

          // Make GA4 API request with retry
          let responseTime = 0;
          const r = await withRetry(async () => {
            const response = await fetchWithTimeout(api, {
              method: 'POST',
              headers: {
                Authorization: `Bearer ${token}`,
                'Content-Type': 'application/json',
              },
              body: JSON.stringify(body),
            }, 30000); // 30 second timeout for GA4 API
            
            if (!response.ok) {
              const errorText = await response.text();
              console.error('GA4 API error:', response.status, errorText);
              
              // Handle quota exceeded specifically
              if (response.status === 429) {
                const retryAfter = response.headers.get('Retry-After');
                throw new QuotaExceededError(0, retryAfter || undefined);
              }
              
              // Throw Response object for retry logic
              if (response.status >= 500) {
                throw response;
              }
              
              // Check for quota errors in response body
              if (errorText.toLowerCase().includes('quota')) {
                throw new QuotaExceededError();
              }
              
              // Non-retryable errors
              throw new Error(`GA4 API error: ${response.status} - ${errorText}`);
            }
            
            responseTime = performance.now() - startTime;
            return response;
          }, {
            maxRetries: 3,
            shouldRetry: (error, attempt) => {
              // Quota errors: be more conservative with retries
              if (isQuotaError(error)) {
                console.warn(`Quota error detected, attempt ${attempt + 1}`);
                return attempt < 2; // Only retry once for quota errors
              }
              
              // Server errors: normal retry
              if (error instanceof Response && error.status >= 500) {
                return attempt < 3;
              }
              
              // Network errors: retry with limit
              if (error instanceof Error) {
                const message = error.message.toLowerCase();
                if (message.includes('fetch failed') || 
                    message.includes('network') ||
                    message.includes('timeout')) {
                  return attempt < 3; // Limit network error retries
                }
              }
              
              return false;
            }
          });
          
          const data = await r.json();
          
          // Check for error response
          if (isGA4Error(data)) {
            console.error('GA4 API returned error:', data.error);
            
            // Check if it's a quota error
            const errorMessage = data.error.message.toLowerCase();
            if (data.error.code === 429 || errorMessage.includes('quota')) {
              throw new QuotaExceededError();
            }
            
            throw new Error(`GA4 API error: ${data.error.message}`);
          }
          
          // Validate response structure
          if (!validateGA4Response(data)) {
            console.error('Invalid GA4 response structure:', JSON.stringify(data).slice(0, 200));
            throw new Error('Invalid GA4 response structure');
          }
          
          const ga4Data = data as GA4Response;
          // Extract metric value based on API type
          const rawValue =
            metric === 'activeUsers'
              ? ga4Data.rows?.[0]?.metricValues?.[0]?.value ?? '0'  // Realtime: only rows
              : findAggregatedValue(ga4Data, 'TOTAL') ?? ga4Data.rows?.[0]?.metricValues?.[0]?.value ?? '0';  // Core: look for aggregated value
          
          const numericValue = parseMetricValue(rawValue);
          
          // Log metrics and quota information
          const ga4Metrics: GA4Metrics = {
            endpoint: metric === 'activeUsers' ? 'realtime' : 'core',
            metricType: metric,
            responseTime: responseTime || performance.now() - startTime,
            cacheHit: false,
            tokensConsumed: ga4Data.propertyQuota?.tokensConsumed,
            tokensRemaining: ga4Data.propertyQuota?.tokensRemaining
          };
          
          log<GA4Metrics>({
            timestamp: new Date().toISOString(),
            service: 'ga4-api',
            level: 'info',
            message: 'GA4 API request completed',
            metadata: ga4Metrics
          });
          
          // Warn if quota is running low
          if (ga4Data.propertyQuota?.tokensRemaining && 
              ga4Data.propertyQuota.tokensRemaining < 200) {
            log({
              timestamp: new Date().toISOString(),
              service: 'ga4-api',
              level: 'warn',
              message: `GA4 quota running low: ${ga4Data.propertyQuota.tokensRemaining} tokens remaining`,
              metadata: {
                tokensRemaining: ga4Data.propertyQuota.tokensRemaining,
                endpoint: metric === 'activeUsers' ? 'realtime' : 'core'
              }
            });
          }

          // Use dynamic cache control based on quota
          const cacheControl = calculateCacheControl(metric, ga4Data.propertyQuota);

          return {
            metric,
            value: numericValue,
            cacheControl,
            quota: ga4Data.propertyQuota  // Pass quota info for dynamic caching
          };
        });
        
        // Extract values from deduplication result
        const { metric, value: numericValue, cacheControl, quota } = result;
        const corsHeaders = getCorsHeaders(req, env);
        
        // Add quota warning header if running low
        const headers: HeadersInit = {
          'Cache-Control': cacheControl,
          ...corsHeaders
        };
        
        if (quota?.tokensRemaining && quota.tokensRemaining < 200) {
          headers['X-GA-Quota-Warning'] = `Low quota: ${quota.tokensRemaining} tokens remaining`;
        }

        return Response.json(
          metric === 'activeUsers' ? { online: numericValue } : { total: numericValue },
          { headers },
        );
      } catch (error) {
        log({
          timestamp: new Date().toISOString(),
          service: 'ga4-api',
          level: 'error',
          message: 'Stats API error',
          metadata: {
            error: error instanceof Error ? error.message : String(error),
            isQuotaError: isQuotaError(error),
            endpoint: url.searchParams.get('t') || 'unknown'
          }
        });
        
        // Return appropriate error response
        const isQuota = isQuotaError(error);
        return new Response(JSON.stringify({ 
          error: isQuota ? 'API quota exceeded, please try again later' : 'Service temporarily unavailable' 
        }), { 
          status: isQuota ? 429 : 503,
          headers: { 
            'Content-Type': 'application/json',
            'Retry-After': isQuota ? '300' : '60'  // 5 min for quota, 1 min for others
          }
        });
      }
    }

    // Handle CORS preflight requests
    if (req.method === 'OPTIONS') {
      return new Response(null, {
        headers: getCorsHeaders(req, env),
      });
    }

    // ---------------------------------------------------------- Static file handler
    return env.ASSETS.fetch(req);
  },
};

// ---------- Helper Functions ----------------------------------------------------------
async function getAccessToken(env: Env, ctx: ExecutionContext): Promise<string> {
  // Try to get cached token
  const cache = caches.default;
  const cacheKey = new Request(`https://cache.internal/${CONFIG.CACHE.TOKEN_KEY}`);
  const cached = await cache.match(cacheKey);
  
  if (cached) {
    const token = await cached.text();
    if (token) return token;
  }

  // Generate new token with retry
  const jwt = await buildJWT(env);
  const token = await withRetry(
    () => exchangeForAccessToken(jwt),
    { maxRetries: 2 } // Less retries for token exchange
  );
  
  // Cache the token
  ctx.waitUntil(
    cache.put(
      cacheKey,
      new Response(token, {
        headers: {
          'Cache-Control': `max-age=${CONFIG.CACHE.TOKEN_TTL}`,
        },
      })
    )
  );

  return token;
}

async function buildJWT(env: Env): Promise<string> {
  const key: ServiceAccountKey = JSON.parse(env.GA4_SERVICE_KEY);

  const header = { 
    alg: 'RS256', 
    typ: 'JWT',
    kid: key.private_key_id // Add key ID for better key management
  };
  const iat = Math.floor(Date.now() / 1000);
  const exp = iat + 3600; // 1h

  const payload = {
    iss: key.client_email,
    scope: CONFIG.GA4.SCOPES,
    aud: 'https://oauth2.googleapis.com/token',
    exp,
    iat,
  };

  const enc = (obj: unknown): string => {
    const json = JSON.stringify(obj);
    const b64 = btoa(json);
    return b64.replace(/\+/g, '-').replace(/\//g, '_').replace(/=/g, '');
  };

  const unsigned = `${enc(header)}.${enc(payload)}`;
  const cryptoKey = await crypto.subtle.importKey(
    'pkcs8',
    pemToArrayBuffer(key.private_key),
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
    false,
    ['sign'],
  );

  const sig = await crypto.subtle.sign(
    'RSASSA-PKCS1-v1_5',
    cryptoKey,
    new TextEncoder().encode(unsigned),
  );

  return `${unsigned}.${arrayBufferToBase64Url(sig)}`;
}

async function exchangeForAccessToken(jwt: string): Promise<string> {
  const res = await fetchWithTimeout(CONFIG.GA4.TOKEN_URL, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: `grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=${jwt}`,
  }, 15000); // 15 second timeout for token exchange
  
  if (!res.ok) {
    const errorText = await res.text();
    console.error(`Token exchange failed: ${res.status}`, errorText);
    throw new Error(`Token exchange failed: ${res.status} - ${errorText}`);
  }
  
  const tokenResponse: TokenResponse = await res.json();
  
  if (!tokenResponse.access_token) {
    throw new Error('Invalid token response: missing access_token');
  }
  
  return tokenResponse.access_token;
}

// Convert PEM string to ArrayBuffer
function pemToArrayBuffer(pem: string): ArrayBuffer {
  const b64 = pem
    .replace('-----BEGIN PRIVATE KEY-----', '')
    .replace('-----END PRIVATE KEY-----', '')
    .replace(/\s+/g, '');
  const bin = atob(b64);
  const buf = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) buf[i] = bin.charCodeAt(i);
  return buf.buffer;
}

function arrayBufferToBase64Url(buf: ArrayBuffer): string {
  const uint8Array = new Uint8Array(buf);
  const chunkSize = 8192; // Process in chunks to avoid stack overflow
  let binary = '';
  
  // Process in chunks to handle large buffers safely
  for (let i = 0; i < uint8Array.length; i += chunkSize) {
    const chunk = uint8Array.slice(i, Math.min(i + chunkSize, uint8Array.length));
    // Use apply with Array.from to avoid spread operator issues
    binary += String.fromCharCode.apply(null, Array.from(chunk));
  }
  
  const b64 = btoa(binary);
  return b64.replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}