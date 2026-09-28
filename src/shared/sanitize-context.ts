/**
 * Context Image Sanitizer & Multimodal Transmuter.
 *
 * Resolves the model-switching dilemma where multimodal models (like DeepSeek-V4.1-Flash)
 * accept image attachments, but subsequent text-only reasoning models (like DeepSeek-V4.1-Pro,
 * DeepSeek-V3, and DeepSeek-R1) fail with `400 invalid_request_error: model does not support image input`.
 *
 * This utility inspects the message history, identifies image payloads (base64, data URLs,
 * binary image blocks, or markdown image references), and transmutes them into lightweight
 * text stubs preserving conversational context, filenames, and previous assistant analysis.
 */

export interface MessageContentPart {
  type: string;
  text?: string;
  image_url?: { url: string; detail?: string };
  image?: { source?: { type: string; data?: string; media_type?: string } };
  [key: string]: unknown;
}

export interface ChatCompletionMessage {
  role: "system" | "user" | "assistant" | "tool";
  content: string | MessageContentPart[];
  name?: string;
  tool_calls?: unknown[];
  reasoning_content?: string;
  [key: string]: unknown;
}

export interface SanitizeOptions {
  /** If true, forces sanitization regardless of target model capabilities. */
  force?: boolean;
  /** Custom stub message prefix. */
  stubPrefix?: string;
  /** Maximum length of data URI summary before truncation. */
  truncateDataUriLength?: number;
}

/**
 * Known multimodal models in the fleet that natively accept image inputs.
 */
export const MULTIMODAL_MODELS: readonly string[] = [
  "deepseek-v4.1-flash",
  "minimax-m3.1-flash-preview",
  "gpt-4o",
  "gpt-4o-mini",
  "claude-3-5-sonnet",
  "claude-3-7-sonnet",
  "claude-3-haiku",
  "gemini-1.5-pro",
  "gemini-1.5-flash",
  "gemini-2.0-flash",
  "gemini-2.5-pro",
];

/**
 * Checks if a given model identifier natively supports multimodal/image input.
 */
export function isMultimodalModel(model: string): boolean {
  const normalized = model.toLowerCase().trim();
  return MULTIMODAL_MODELS.some((m) => normalized.includes(m));
}

/**
 * Replaces markdown inline image syntax `![alt](url)` with a sanitized stub if it's a data URL.
 */
function sanitizeMarkdownImages(text: string): string {
  // Replace base64 data URIs in markdown images: ![caption](data:image/...;base64,...)
  return text.replace(/!\[(.*?)\]\(data:image\/[^;]+;base64,[^)]+\)/gu, (_match, caption) => {
    const label = caption && caption.trim().length > 0 ? caption.trim() : "Embedded Image";
    return `[Image attachment '${label}' omitted for text-only model compatibility.  Prior visual analysis is preserved in thread.]`;
  });
}

/**
 * Transmutes a single message part into a text-only representation.
 */
function sanitizePart(part: MessageContentPart, _options: SanitizeOptions): MessageContentPart {
  if (typeof part === "string") {
    return { type: "text", text: sanitizeMarkdownImages(part) };
  }

  // OpenAI image_url format: { type: "image_url", image_url: { url: "data:..." } }
  if (part.type === "image_url" && part.image_url?.url) {
    const url = part.image_url.url;
    let label = "Attached Image";
    if (url.startsWith("data:image/")) {
      const mime = url.substring(5, url.indexOf(";"));
      label = `Data Image (${mime})`;
    } else {
      label = url.split("/").pop() || url;
    }
    return {
      type: "text",
      text: `[Image attachment '${label}' removed for text-only model compatibility.  Prior visual findings remain valid in thread context.]`,
    };
  }

  // Anthropic source format: { type: "image", source: { type: "base64", media_type: "...", data: "..." } }
  if (part.type === "image") {
    return {
      type: "text",
      text: "[Image attachment removed for text-only model compatibility.  Prior visual analysis remains active.]",
    };
  }

  // Text part with potential markdown images
  if (part.type === "text" && typeof part.text === "string") {
    return {
      ...part,
      text: sanitizeMarkdownImages(part.text),
    };
  }

  return part;
}

/**
 * Sanitizes an array of chat completion messages for a target model.
 *
 * If the target model is multimodal (e.g. DeepSeek-V4.1-Flash), messages are returned
 * untouched.  If the target model is text-only (e.g. DeepSeek-V4.1-Pro, DeepSeek-V3),
 * all image blocks and base64 payloads are replaced with lightweight textual stubs.
 */
export function sanitizeMessagesForModel(
  messages: readonly ChatCompletionMessage[],
  targetModel: string,
  options: SanitizeOptions = {},
): ChatCompletionMessage[] {
  const requiresSanitization = options.force || !isMultimodalModel(targetModel);
  if (!requiresSanitization) {
    return [...messages];
  }

  return messages.map((msg) => {
    // If content is a simple string, sanitize any markdown data URI images
    if (typeof msg.content === "string") {
      const cleaned = sanitizeMarkdownImages(msg.content);
      if (cleaned === msg.content) return msg;
      return { ...msg, content: cleaned };
    }

    // If content is an array of parts
    if (Array.isArray(msg.content)) {
      const sanitizedParts = msg.content.map((part) => sanitizePart(part, options));
      return {
        ...msg,
        content: sanitizedParts,
      };
    }

    return msg;
  });
}
