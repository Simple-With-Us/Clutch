import { describe, expect, it } from "vitest";
import {
  isMultimodalModel,
  sanitizeMessagesForModel,
  type ChatCompletionMessage,
} from "../src/shared/sanitize-context.ts";

describe("context-sanitizer", () => {
  it("identifies multimodal models vs text-only models", () => {
    // Multimodal models that support images
    expect(isMultimodalModel("DeepSeek-V4.1-Flash")).toBe(true);
    expect(isMultimodalModel("deepseek-v4.1-flash")).toBe(true);
    expect(isMultimodalModel("MiniMax-M3.1-Flash-Preview")).toBe(true);
    // The plain M3 is image-capable in the installed pi-ai catalog
    // (`input: [text, image]`), so it must not be sanitized either.
    expect(isMultimodalModel("MiniMax-M3")).toBe(true);
    expect(isMultimodalModel("claude-3-5-sonnet")).toBe(true);
    expect(isMultimodalModel("gpt-4o")).toBe(true);

    // Text-only reasoning/coding models that reject images
    expect(isMultimodalModel("DeepSeek-V4.1-Pro")).toBe(false);
    expect(isMultimodalModel("deepseek-v3")).toBe(false);
    expect(isMultimodalModel("deepseek-r1")).toBe(false);
    // The M2.7 family is `input: [text]` upstream, so an image heading for it
    // still has to be transmuted into a text stub.
    expect(isMultimodalModel("MiniMax-M2.7-highspeed")).toBe(false);
    expect(isMultimodalModel("MiniMax-M2.7")).toBe(false);
  });

  it("leaves messages untouched when target model is multimodal", () => {
    const messages: ChatCompletionMessage[] = [
      {
        role: "user",
        content: [
          { type: "text", text: "What is on this screen?" },
          {
            type: "image_url",
            image_url: { url: "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==" },
          },
        ],
      },
    ];

    const result = sanitizeMessagesForModel(messages, "DeepSeek-V4.1-Flash");
    expect(result).toEqual(messages);
  });

  it("sanitizes image_url parts when switching to DeepSeek-V4.1-Pro or DeepSeek-V3", () => {
    const messages: ChatCompletionMessage[] = [
      {
        role: "user",
        content: [
          { type: "text", text: "Review this bug report and the attached screenshot." },
          {
            type: "image_url",
            image_url: { url: "data:image/png;base64,abc123payload" },
          },
        ],
      },
      {
        role: "assistant",
        content: "I see a 404 error on line 42 of the dashboard layout.",
      },
      {
        role: "user",
        content: "Can you fix the Swift code for it now?",
      },
    ];

    const sanitized = sanitizeMessagesForModel(messages, "DeepSeek-V4.1-Pro");

    // First message content parts should be sanitized
    const firstContent = sanitized[0]?.content as Array<{ type: string; text?: string }>;
    expect(firstContent).toHaveLength(2);
    expect(firstContent[0]?.text).toBe("Review this bug report and the attached screenshot.");
    expect(firstContent[1]?.type).toBe("text");
    expect(firstContent[1]?.text).toContain("Image attachment");
    expect(firstContent[1]?.text).toContain("removed for text-only model compatibility");

    // Subsequent messages and assistant analysis must remain completely preserved
    expect(sanitized[1]?.content).toBe("I see a 404 error on line 42 of the dashboard layout.");
    expect(sanitized[2]?.content).toBe("Can you fix the Swift code for it now?");
  });

  it("sanitizes inline markdown base64 images in string messages", () => {
    const messages: ChatCompletionMessage[] = [
      {
        role: "user",
        content: "Here is the error dialog: ![Xcode Build Error](data:image/png;base64,iVBORw0KGgoAAAANSUhEUgA...) How do I fix it?",
      },
    ];

    const sanitized = sanitizeMessagesForModel(messages, "DeepSeek-V3");
    expect(typeof sanitized[0]?.content).toBe("string");
    expect(sanitized[0]?.content).toContain("Here is the error dialog: [Image attachment 'Xcode Build Error' omitted for text-only model compatibility.");
    expect(sanitized[0]?.content).toContain("How do I fix it?");
    expect(sanitized[0]?.content).not.toContain("data:image/png;base64");
  });

  it("forces sanitization if explicitly requested via options", () => {
    const messages: ChatCompletionMessage[] = [
      {
        role: "user",
        content: [
          {
            type: "image_url",
            image_url: { url: "https://example.com/mockup.png" },
          },
        ],
      },
    ];

    const sanitized = sanitizeMessagesForModel(messages, "DeepSeek-V4.1-Flash", { force: true });
    const content = sanitized[0]?.content as Array<{ type: string; text?: string }>;
    expect(content[0]?.type).toBe("text");
    expect(content[0]?.text).toContain("mockup.png");
  });
});
