const escapeHtml = value => String(value).replace(/[&<>"']/g, char => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[char]));

export function verificationEmailHtml(url, hours) {
    const link = escapeHtml(url);
    // Inline table styles keep the account email readable in Gmail and Outlook.
    return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Verify your EcoPin email</title></head>
<body style="margin:0;background:#F5F7FA;color:#17212E;font-family:Outfit,Arial,sans-serif">
<table role="presentation" width="100%" cellspacing="0" cellpadding="0"><tr><td align="center" style="padding:32px 16px">
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="max-width:560px;background:#FFFFFF;border:1px solid #E5E9EE;border-radius:24px"><tr><td style="padding:32px">
<p style="margin:0 0 32px;color:#0052CC;font-size:24px;font-weight:700">EcoPin</p>
<h1 style="margin:0 0 16px;font-size:28px;line-height:1.25">Verify your email address</h1>
<p style="font-size:16px;line-height:1.6;color:#59636E">One more step to set up your account. Confirm your email to start reporting environmental concerns and follow what happens next.</p>
<table role="presentation" cellspacing="0" cellpadding="0" style="margin:24px 0"><tr><td bgcolor="#0052CC" style="border-radius:999px"><a href="${link}" style="display:inline-block;padding:16px 24px;color:#FFFFFF;font-size:16px;font-weight:600;text-decoration:none">Verify email address</a></td></tr></table>
<p style="font-size:14px;line-height:1.6;color:#59636E">This link expires in ${hours} hours. After verifying, return to Ecopin and sign in.</p>
<p style="font-size:14px;line-height:1.6;color:#59636E">Button not working? Copy this link into your browser:<br><a href="${link}" style="color:#0052CC;word-break:break-all">${link}</a></p>
<p style="margin:24px 0 0;padding-top:24px;border-top:1px solid #E5E9EE;font-size:14px;line-height:1.6;color:#59636E">If you did not create an account, you can ignore this email.</p>
</td></tr></table></td></tr></table></body></html>`;
}

export function renderVerificationHtml(message, isSuccess) {
    return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="color-scheme" content="light dark"><meta name="referrer" content="no-referrer"><title>${isSuccess ? 'Email verified' : 'Email verification'} · EcoPin</title>
<style> *{box-sizing:border-box} body{margin:0;min-height:100dvh;display:grid;place-items:center;padding:24px;background:#F5F7FA;color:#17212E;font-family:Outfit,Arial,sans-serif;line-height:1.6} main{width:100%;max-width:480px;background:#FFFFFF;border:1px solid #E5E9EE;border-radius:24px;padding:32px} .brand{color:#0052CC;font-size:24px;font-weight:700;margin:0 0 32px} h1{font-size:28px;line-height:1.25;margin:0 0 16px} p{color:#59636E} .button{display:inline-block;min-height:48px;padding:12px 24px;border-radius:999px;background:#0052CC;color:white;text-decoration:none;font-weight:600} a:focus-visible{outline:3px solid #0052CC;outline-offset:4px} @media(prefers-color-scheme:dark){body{background:#121212;color:#F5F5F5}main{background:#1C1C1C;border-color:#333333}p{color:#B0B0B0}.brand{color:#82B6FF}}</style></head>
<body><main><p class="brand">EcoPin</p><h1>${isSuccess ? 'Your email is verified' : 'We couldn’t verify this link'}</h1><p>${escapeHtml(message)}</p>
${isSuccess ? '<p>Return to Ecopin and sign in to continue.</p><a class="button" href="ecopin://auth/verified">Open Ecopin</a>' : '<p>Return to the email verification screen in Ecopin and select <strong>Resend verification email</strong>. Wait at least 60 seconds between requests, then check your inbox and spam folder. Open the newest email.</p>'}
</main></body></html>`;
}
