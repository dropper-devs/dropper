"use client";

import { useState } from "react";
import Reveal from "@/components/Reveal";
import { WizardArrow, BenefitIcon } from "@/components/ui/icons";

const STEPS = [
  {
    title: "See what you’ll need",
    description: "A free account, R2’s free tier, and about three minutes.",
    image: "/wizard/1.png",
    alt: "Dropper setup introduction listing the three things needed",
  },
  {
    title: "Sign in to Cloudflare",
    description: "Create a free account or use the one you already have.",
    image: "/wizard/2.png",
    alt: "Dropper wizard step for creating or signing in to a Cloudflare account",
  },
  {
    title: "Enable R2 storage",
    description:
      "The wizard opens the right dashboard page. One click turns it on.",
    image: "/wizard/3.png",
    alt: "Dropper wizard step for enabling Cloudflare R2 storage",
  },
  {
    title: "Paste one token",
    description:
      "Dropper creates the bucket, enables its public URL, and configures itself.",
    image: "/wizard/4.png",
    alt: "Dropper wizard API token step where the app completes its configuration",
  },
] as const;

export default function SetupWizard() {
  const [activeStep, setActiveStep] = useState(0);
  const step = STEPS[activeStep];

  return (
    <section id="setup" className="setup-wizard-section">
      <div className="container">
        <Reveal>
          <div className="setup-wizard-heading">
            <p className="section-kicker">Easy setup</p>
            <h2 className="section-title">We&apos;ll help you get set up.</h2>
            <p className="section-lede">
              Dropper&apos;s setup wizard walks you through Cloudflare, so you
              don&apos;t need to know the ins and outs. Paste one API token and
              Dropper handles the rest.
            </p>
            <ul className="setup-wizard-promises" aria-label="Setup benefits">
              <li>
                <BenefitIcon kind="clock" />
                About three minutes
              </li>
              <li>
                <BenefitIcon kind="check" />
                No R2 experience needed
              </li>
              <li>
                <BenefitIcon kind="lock" />
                Token stored in Keychain
              </li>
            </ul>
          </div>
        </Reveal>

        <Reveal delay={100}>
          <div className="setup-wizard-stage">
            <div className="setup-wizard-preview">
              <a
                className="setup-wizard-screen"
                href={step.image}
                target="_blank"
                rel="noopener noreferrer"
                aria-label={`Open step ${activeStep + 1} screenshot at full size`}
              >
                {/* These UI captures must stay lossless. A plain img bypasses
                    Next's WebP conversion and serves the original PNG. */}
                <img
                  key={step.image}
                  src={step.image}
                  alt={step.alt}
                  width={500}
                  height={673}
                  loading="lazy"
                  decoding="async"
                />
                <span className="setup-wizard-zoom">View full size</span>
              </a>
              <div className="setup-wizard-preview-footer">
                <p aria-live="polite">
                  <span>
                    Step {activeStep + 1} of {STEPS.length}
                  </span>
                  {step.title}
                </p>
                <div className="setup-wizard-arrows">
                  <button
                    type="button"
                    onClick={() => setActiveStep(activeStep - 1)}
                    disabled={activeStep === 0}
                    aria-label="Previous setup step"
                  >
                    <WizardArrow direction="left" />
                  </button>
                  <button
                    type="button"
                    onClick={() => setActiveStep(activeStep + 1)}
                    disabled={activeStep === STEPS.length - 1}
                    aria-label="Next setup step"
                  >
                    <WizardArrow direction="right" />
                  </button>
                </div>
              </div>
            </div>

            <div className="setup-wizard-guide">
              <ol
                className="setup-wizard-steps"
                aria-label="Dropper setup steps"
              >
                {STEPS.map((item, index) => (
                  <li key={item.image}>
                    <button
                      type="button"
                      className={index === activeStep ? "active" : undefined}
                      onClick={() => setActiveStep(index)}
                      aria-current={index === activeStep ? "step" : undefined}
                    >
                      <span className="setup-wizard-number">{index + 1}</span>
                      <span className="setup-wizard-step-copy">
                        <strong>{item.title}</strong>
                        <span>{item.description}</span>
                      </span>
                    </button>
                  </li>
                ))}
              </ol>

              <div className="setup-wizard-done">
                <span className="setup-wizard-check" aria-hidden="true">
                  ✓
                </span>
                <p>
                  <strong>That&apos;s the whole setup.</strong> After this,
                  sharing is just drop, paste, done.
                </p>
              </div>
            </div>
          </div>
        </Reveal>
      </div>
    </section>
  );
}
