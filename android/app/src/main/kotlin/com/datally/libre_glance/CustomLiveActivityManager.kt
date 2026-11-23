package com.datally.libre_glance

import android.app.Notification
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import com.istornz.live_activities.LiveActivityManager

/** Silent, persistent, low-priority notification showing "value + trend arrow". */
class CustomLiveActivityManager(context: Context) : LiveActivityManager(context) {
    private val appContext: Context = context.applicationContext

    private val pendingIntent = PendingIntent.getActivity(
        appContext, 200,
        Intent(appContext, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
        },
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
    )

    private fun arrow(trend: Int) = when (trend) {
        1 -> "↓"
        2 -> "↘"
        4 -> "↗"
        5 -> "↑"
        else -> "→"
    }

    // Keys are written by lib/services/live_activity_manager.dart.
    override suspend fun buildNotification(
        notification: Notification.Builder,
        event: String,
        data: Map<String, Any>
    ): Notification {
        val value = (data["glucose"] as Number).toInt()
        val trend = (data["trend"] as Number).toInt()
        val min = (data["min"] as Number).toInt()
        val max = (data["max"] as Number).toInt()
        val label = when {
            value < min -> "Bas"
            value > max -> "Élevé"
            else -> "Dans la cible"
        }
        return notification
            .setSmallIcon(R.mipmap.ic_launcher)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentTitle("$value mg/dL ${arrow(trend)}")
            .setContentText("$label · ${data["patient"]}")
            .setContentIntent(pendingIntent)
            .setPriority(Notification.PRIORITY_LOW)
            .setCategory(Notification.CATEGORY_STATUS)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .build()
    }
}
