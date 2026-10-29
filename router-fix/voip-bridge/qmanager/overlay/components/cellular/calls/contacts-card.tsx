"use client";

import { useRef, useState } from "react";
import { useTranslation } from "react-i18next";
import {
  PhoneCallIcon,
  Trash2Icon,
  UploadIcon,
  UserPlusIcon,
} from "lucide-react";

import MaskedText from "@/components/masked-text";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import type { CallTerminal } from "@/hooks/use-call-terminal";
import { useReveal } from "@/hooks/use-reveal";
import { cn } from "@/lib/utils";

import {
  CARD_HEAD,
  CARD_PAD,
  CARD_SHELL,
  CARD_TITLE,
  CONTACT_ROW,
  FOOTNOTE,
  IMPORT_ROW,
  NOTICE,
  SECTION_LABEL,
} from "./shapes";

// =============================================================================
// ContactsCard — the address book, and the vCard import that fills it
// =============================================================================
// The book lives on the device (/data/webrtc/contacts.json), not in this browser:
// a phone book that exists only in one tab is lost the first time somebody opens
// the UI on their phone, and it is what turns a call log of digits into names.
//
// -----------------------------------------------------------------------------
// IMPORT IS A FILE PICKER, NOT A MULTIPART UPLOAD
// -----------------------------------------------------------------------------
// The page reads the .vcf and posts its text. That keeps the bridge free of a
// form parser, and it means the same button works for an export from iOS,
// Android, Google Contacts or Thunderbird without caring which one it was.
//
// A contact needs a NUMBER to be useful here: rows without one are counted as
// skipped rather than stored, because nothing on this page can dial or match them.
// =============================================================================

const K = "calls";

interface ContactsCardProps {
  terminal: CallTerminal;
}

const ContactsCard = ({ terminal }: ContactsCardProps) => {
  const { t } = useTranslation("common");
  const { revealed } = useReveal();
  const { contacts } = terminal;

  const [name, setName] = useState("");
  const [phone, setPhone] = useState("");
  const [status, setStatus] = useState<string | null>(null);
  const fileRef = useRef<HTMLInputElement | null>(null);

  const add = async () => {
    if (phone.trim() === "") {
      setStatus(t(`${K}.contacts.need_number`));
      return;
    }
    await terminal.saveContact({ name: name.trim(), phone: phone.trim(), company: "", email: "" });
    setName("");
    setPhone("");
    setStatus(null);
  };

  const importFile = async (file: File) => {
    const text = await file.text();
    const res = await terminal.importVcf(text);
    setStatus(
      res
        ? t(`${K}.contacts.imported`, {
            imported: res.imported,
            updated: res.updated,
            skipped: res.skipped,
          })
        : t(`${K}.contacts.import_failed`)
    );
    if (fileRef.current) {
      fileRef.current.value = "";
    }
  };

  return (
    <Card className={cn(CARD_SHELL, CARD_PAD)}>
      <CardHeader className={CARD_HEAD.ROOT}>
        <div className={CARD_HEAD.TITLES}>
          <CardTitle className={CARD_TITLE}>{t(`${K}.contacts.title`)}</CardTitle>
          <p className={CARD_HEAD.DESC}>{t(`${K}.contacts.description`)}</p>
        </div>
        <div className={CARD_HEAD.ACTIONS}>
          <span className={SECTION_LABEL}>
            {t(`${K}.contacts.count`, { n: contacts.length })}
          </span>
        </div>
      </CardHeader>

      <CardContent className="flex flex-col gap-4 px-0">
        <div className={IMPORT_ROW}>
          <input
            ref={fileRef}
            type="file"
            accept=".vcf,text/vcard,text/x-vcard"
            className="hidden"
            onChange={(e) => {
              const f = e.target.files?.[0];
              if (f) {
                void importFile(f);
              }
            }}
          />
          <Button
            type="button"
            variant="tonal-neutral"
            size="action"
            onClick={() => fileRef.current?.click()}
          >
            <UploadIcon className="size-4" />
            {t(`${K}.contacts.import`)}
          </Button>
          <span className={SECTION_LABEL}>{t(`${K}.contacts.import_hint`)}</span>
        </div>

        <div className={IMPORT_ROW}>
          <Input
            className="h-10 @lg/card:flex-1"
            placeholder={t(`${K}.contacts.name_placeholder`)}
            value={name}
            onChange={(e) => setName(e.target.value)}
            aria-label={t(`${K}.contacts.name_placeholder`)}
          />
          <Input
            className="h-10 font-mono tabular-nums @lg/card:flex-1"
            placeholder={t(`${K}.contacts.phone_placeholder`)}
            value={phone}
            inputMode="tel"
            onChange={(e) => setPhone(e.target.value.replace(/[^0-9*#+]/g, ""))}
            aria-label={t(`${K}.contacts.phone_placeholder`)}
            onKeyDown={(e) => {
              if (e.key === "Enter") {
                e.preventDefault();
                void add();
              }
            }}
          />
          <Button type="button" variant="default" size="action" onClick={() => void add()}>
            <UserPlusIcon className="size-4" />
            {t(`${K}.contacts.add`)}
          </Button>
        </div>

        {status ? (
          <p className="text-on-surface-variant text-[0.8125rem] leading-relaxed">{status}</p>
        ) : null}

        {contacts.length === 0 ? (
          <div className={NOTICE.ROOT}>
            <p className={NOTICE.TITLE}>{t(`${K}.contacts.empty_title`)}</p>
            <p className={NOTICE.BODY}>{t(`${K}.contacts.empty_body`)}</p>
          </div>
        ) : (
          <div className="flex max-h-[22rem] flex-col gap-2 overflow-y-auto">
            {contacts.map((c) => (
              <div key={c.id} className={CONTACT_ROW.ROOT}>
                <div className={CONTACT_ROW.TEXT}>
                  <MaskedText
                    className={CONTACT_ROW.NAME}
                    value={c.name || c.phone}
                    number={!c.name}
                    revealed={revealed}
                  />
                  <span className={CONTACT_ROW.META}>
                    {c.name ? <MaskedText value={c.phone} number revealed={revealed} /> : ""}
                    {c.company ? ` · ${c.company}` : ""}
                  </span>
                </div>
                <Button
                  type="button"
                  variant="tonal-neutral"
                  size="icon-sm"
                  aria-label={t(`${K}.contacts.call`)}
                  onClick={() => {
                    void terminal.dial(c.phone);
                  }}
                >
                  <PhoneCallIcon className="size-4" />
                </Button>
                <Button
                  type="button"
                  variant="tonal-destructive"
                  size="icon-sm"
                  aria-label={t(`${K}.contacts.delete`)}
                  onClick={() => void terminal.deleteContact(c.id)}
                >
                  <Trash2Icon className="size-4" />
                </Button>
              </div>
            ))}
          </div>
        )}

        <p className={FOOTNOTE}>{t(`${K}.contacts.footnote`)}</p>
      </CardContent>
    </Card>
  );
};

export default ContactsCard;
