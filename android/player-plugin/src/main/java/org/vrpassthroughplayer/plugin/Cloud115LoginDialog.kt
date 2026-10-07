package org.vrpassthroughplayer.plugin

import android.app.Activity
import android.app.Dialog
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.os.SystemClock
import android.text.InputType
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.widget.*
import java.util.concurrent.Executors

/** Native inputs and large captcha targets work with Quest's system keyboard and controller ray. */
internal class Cloud115LoginDialog(
    private val activity: Activity,
    private val connected: (String) -> Unit,
    private val auth: Cloud115Auth = Cloud115Auth()
) : Dialog(activity) {
    private val worker = Executors.newSingleThreadExecutor()
    private fun tr(en: String, zh: String) = UiLanguage.tr(context, en, zh)
    private fun dp(value: Int) = (value * context.resources.displayMetrics.density).toInt()
    private val content = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL; setPadding(dp(24), dp(16), dp(24), dp(16)) }
    private val account = input(tr("115 account / phone number", "115 账号 / 手机号"))
    private val password = input(tr("Password", "密码"), true)
    private val hint = TextView(context).apply { textSize = 16f; setTextColor(Color.rgb(145, 55, 40)) }
    private val challengeBox = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL }
    private val smsBox = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL; visibility = View.GONE }
    private val smsCode = input(tr("SMS code", "短信验证码")).apply { inputType = InputType.TYPE_CLASS_NUMBER }
    private val controls = ArrayList<View>()
    private lateinit var signIn: Button
    private var busy = false
    private var closed = false
    private var secret = CharArray(0)
    private var loginAccount = ""
    private var sms: Cloud115Auth.Result.Sms? = null
    private var smsSent = false
    private var nextSmsAt = 0L
    private var answer: Cloud115Auth.Answer? = null
    private var captchaRetry: ((Cloud115Auth.Answer?, CharArray, String) -> Cloud115Auth.Result)? = null
    private val bitmaps = ArrayList<Bitmap>()

    init {
        setTitle(tr("Sign in to 115", "登录 115"))
        window?.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        content.addView(account)
        content.addView(password)
        content.addView(hint)
        content.addView(challengeBox)
        content.addView(smsBox)
        smsBox.addView(smsCode)
        addButton(smsBox, tr("Send SMS code", "发送验证码")) {
            val pending = sms ?: return@addButton
            if (SystemClock.elapsedRealtime() < nextSmsAt) {
                hint.text = tr("Wait before sending another code.", "请稍后再获取验证码。")
            } else request({ selected, _, _ -> auth.sendSms(pending, selected) })
        }
        addButton(smsBox, tr("Verify and sign in", "验证并登录")) {
            val pending = sms ?: return@addButton
            val code = smsCode.text.toString().trim()
            if (!smsSent || !code.matches(Regex("[0-9]{4,8}"))) {
                hint.text = tr("Send a code first, then enter it.", "请先获取并填写短信验证码。")
            } else request({ selected, savedPassword, savedAccount ->
                if (pending.twoStep) auth.verifySms(pending, code)
                else auth.password(savedAccount, savedPassword, selected, code)
            })
        }
        signIn = addButton(content, tr("Sign in", "登录")) {
            if (account.text.isBlank() || password.text.isEmpty()) {
                hint.text = tr("Enter your account and password.", "请填写账号和密码。")
            } else {
                secret.fill('\u0000')
                secret = CharArray(password.length()) { password.text[it] }
                loginAccount = account.text.toString().trim()
                account.isEnabled = false
                password.isEnabled = false
                request({ selected, savedPassword, savedAccount -> auth.password(savedAccount, savedPassword, selected) })
            }
        }
        addButton(content, tr("Start over", "重新输入")) {
            secret.fill('\u0000'); secret = CharArray(0)
            password.text.clear(); smsCode.text.clear()
            account.isEnabled = true; password.isEnabled = true
            sms = null; smsSent = false; answer = null; captchaRetry = null
            smsBox.visibility = View.GONE
            signIn.visibility = View.VISIBLE
            clearChallenge()
            hint.text = ""
        }
        addButton(content, tr("Cancel", "取消"), gated = false) { dismiss() }
        setContentView(ScrollView(context).apply { addView(content) })
        setOnShowListener {
            window?.setLayout(minOf(dp(560), context.resources.displayMetrics.widthPixels), WindowManager.LayoutParams.WRAP_CONTENT)
            window?.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE)
        }
        setOnDismissListener {
            closed = true
            auth.close()
            worker.shutdownNow()
            // The in-flight worker can only use its own password snapshot.
            secret.fill('\u0000'); secret = CharArray(0)
            password.text.clear(); smsCode.text.clear(); account.text.clear()
            loginAccount = ""; sms = null; answer = null; captchaRetry = null
            clearChallenge()
        }
    }

    private fun input(label: String, secret: Boolean = false) = EditText(context).apply {
        hint = label
        textSize = 20f
        minHeight = dp(56)
        isSingleLine = true
        inputType = InputType.TYPE_CLASS_TEXT or if (secret) InputType.TYPE_TEXT_VARIATION_PASSWORD else InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
        isSaveEnabled = false
        importantForAutofill = View.IMPORTANT_FOR_AUTOFILL_NO
    }

    private fun addButton(parent: LinearLayout, text: String, gated: Boolean = true, action: () -> Unit): Button {
        return Button(context).apply {
            this.text = text; minHeight = dp(52)
            parent.addView(this, LinearLayout.LayoutParams(-1, -2))
            if (gated) controls.add(this)
            setOnClickListener { if (!closed && (!gated || !busy)) action() }
        }
    }

    private fun <T> execute(work: () -> T, done: (T) -> Unit) {
        if (busy || closed) return
        busy = true
        controls.forEach { it.isEnabled = false }
        hint.text = tr("Connecting…", "正在连接…")
        worker.execute {
            val result = runCatching(work)
            activity.runOnUiThread {
                if (closed || activity.isFinishing || activity.isDestroyed) return@runOnUiThread
                busy = false
                controls.forEach { it.isEnabled = true }
                result.onSuccess(done).onFailure {
                    hint.text = tr("Connection failed. Please retry.", "连接失败，请重试。")
                }
            }
        }
    }

    private fun request(action: (Cloud115Auth.Answer?, CharArray, String) -> Cloud115Auth.Result, selected: Cloud115Auth.Answer? = answer) {
        if (busy || closed) return
        // Snapshot on the UI thread. Neither editing nor dismissing can change the running request.
        val passwordSnapshot = secret.copyOf()
        val accountSnapshot = loginAccount
        execute({
            try { action(selected, passwordSnapshot, accountSnapshot) } finally { passwordSnapshot.fill('\u0000') }
        }) { result ->
            when (result) {
                is Cloud115Auth.Result.Connected -> { connected(result.cookie); dismiss() }
                is Cloud115Auth.Result.Captcha -> {
                    captchaRetry = action
                    showChallenge()
                }
                is Cloud115Auth.Result.Sms -> {
                    sms = result; smsSent = false; answer = null; captchaRetry = null
                    if (result.twoStep) { secret.fill('\u0000'); secret = CharArray(0); password.text.clear() }
                    clearChallenge()
                    smsBox.visibility = View.VISIBLE
                    signIn.visibility = View.GONE
                    hint.text = tr("SMS verification required.", "需要短信验证。")
                }
                is Cloud115Auth.Result.Sent -> {
                    smsSent = true; nextSmsAt = SystemClock.elapsedRealtime() + 60000
                    answer = null; captchaRetry = null; clearChallenge()
                    hint.text = tr("Code sent.", "验证码已发送。")
                    smsCode.requestFocus()
                }
                is Cloud115Auth.Result.Rejected -> {
                    hint.text = tr("115 declined sign-in (%s). Check your details or retry later.", "115 未通过登录（%s），请检查输入或稍后重试。").format(result.code)
                }
            }
        }
    }

    private fun clearChallenge() {
        for (i in 0 until challengeBox.childCount) controls.remove(challengeBox.getChildAt(i))
        challengeBox.removeAllViews()
        // Detached views may still have a render node for this frame; let Android reclaim pixels.
        bitmaps.clear()
    }

    private fun image(bytes: ByteArray): Bitmap {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        check(bounds.outWidth in 1..2048 && bounds.outHeight in 1..2048)
        return checkNotNull(BitmapFactory.decodeByteArray(bytes, 0, bytes.size)).also { bitmaps.add(it) }
    }

    private fun showChallenge() {
        answer = null
        clearChallenge()
        execute({ auth.challenge() }) { challenge ->
            runCatching {
                val prompt = image(challenge.prompt)
                val choices = image(challenge.choices)
                check(choices.width >= 5 && choices.height >= 2)
                hint.text = tr("Select the four characters in order.", "依次点选图中的四个字。")
                challengeBox.addView(ImageView(context).apply {
                    setImageBitmap(prompt); scaleType = ImageView.ScaleType.FIT_CENTER
                    contentDescription = tr("Verification characters", "验证码文字")
                }, LinearLayout.LayoutParams(-1, dp(64)))
                val progress = TextView(context).apply { text = "0 / 4"; gravity = Gravity.CENTER; textSize = 20f }
                val preview = LinearLayout(context).apply { gravity = Gravity.CENTER }
                val slots = List(4) {
                    ImageView(context).apply {
                        scaleType = ImageView.ScaleType.FIT_CENTER
                        preview.addView(this, LinearLayout.LayoutParams(dp(52), dp(52)))
                    }
                }
                val selected = ArrayList<Int>()
                repeat(2) { row ->
                    val line = LinearLayout(context)
                    repeat(5) { column ->
                        val index = row * 5 + column
                        val tile = Bitmap.createBitmap(choices, column * choices.width / 5, row * choices.height / 2, choices.width / 5, choices.height / 2).also { bitmaps.add(it) }
                        line.addView(ImageButton(context).apply {
                            setImageBitmap(tile); scaleType = ImageView.ScaleType.FIT_CENTER
                            contentDescription = tr("Character", "文字") + " ${index + 1}"
                            setOnClickListener {
                                if (!busy && selected.size < 4) {
                                    selected.add(index)
                                    slots[selected.lastIndex].setImageBitmap(tile)
                                    progress.text = "${selected.size} / 4"
                                }
                            }
                        }, LinearLayout.LayoutParams(0, dp(64), 1f))
                    }
                    challengeBox.addView(line)
                }
                challengeBox.addView(progress)
                challengeBox.addView(preview)
                addButton(challengeBox, tr("Clear selection", "重选")) {
                    selected.clear(); progress.text = "0 / 4"; slots.forEach { it.setImageDrawable(null) }
                }
                addButton(challengeBox, tr("Continue", "继续")) {
                    if (selected.size == 4) {
                        val value = Cloud115Auth.Answer(challenge.sign, selected.joinToString(""))
                        answer = value
                        captchaRetry?.let { request(it, value) }
                    }
                }
                addButton(challengeBox, tr("Refresh image", "换一张")) { showChallenge() }
            }.onFailure { clearChallenge(); hint.text = tr("Could not load verification image. Retry sign-in.", "验证码加载失败，请重新登录。") }
        }
    }
}
