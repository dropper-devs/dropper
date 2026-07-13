"use server";

import { saveSubscription } from "@/lib/subscriptions";

export type SubscribeActionState =
  | { kind: "idle" }
  | {
      kind: "ok";
      message: string;
      submissionId: string;
    }
  | {
      kind: "err";
      message: string;
      submissionId: string;
      email: string;
    };

export async function subscribeAction(
  _previousState: SubscribeActionState,
  formData: FormData,
): Promise<SubscribeActionState> {
  const email = String(formData.get("email") ?? "");
  const website = String(formData.get("website") ?? "");
  const result = await saveSubscription({ email, website });
  const submissionId = crypto.randomUUID();

  if (result.ok) {
    return {
      kind: "ok",
      message: "You're on the list. Thanks!",
      submissionId,
    };
  }

  return {
    kind: "err",
    message: result.error,
    submissionId,
    email: email.trim().slice(0, 254),
  };
}
