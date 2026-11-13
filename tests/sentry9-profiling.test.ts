import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';

describe('Sentry 9 iOS profiling configuration', () => {
  const source = readFileSync('ios/App/SentryTelemetry.swift', 'utf8');
  it('uses the session profiling API and starts only with sampled traces', () => {
    expect(source).not.toMatch(/options\.profilesSampleRate\s*=/);
    expect(source).toMatch(/options\.configureProfiling\s*=\s*\{\s*profiling in/);
    expect(source).toMatch(/profiling\.lifecycle\s*=\s*\.trace/);
    expect(source).toMatch(/profiling\.sessionSampleRate\s*=\s*0\.1/);
    expect(source).toMatch(/options\.tracesSampleRate\s*=\s*0\.2/);
  });
});
