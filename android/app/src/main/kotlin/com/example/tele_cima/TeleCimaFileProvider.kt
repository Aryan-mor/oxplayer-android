package com.example.tele_cima

import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.provider.OpenableColumns
import androidx.core.content.FileProvider

class TeleCimaFileProvider : FileProvider() {
    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?
    ): Cursor {
        val displayName = uri.getQueryParameter("displayName")
        if (displayName.isNullOrBlank()) {
            return super.query(uri, projection, selection, selectionArgs, sortOrder)
        }

        val baseUri = uri.buildUpon().clearQuery().build()
        val baseCursor = super.query(baseUri, projection, selection, selectionArgs, sortOrder)
            ?: return MatrixCursor(projection ?: arrayOf(OpenableColumns.DISPLAY_NAME))

        val columns = projection ?: baseCursor.columnNames
        if (!columns.contains(OpenableColumns.DISPLAY_NAME)) {
            return baseCursor
        }

        val out = MatrixCursor(columns)
        baseCursor.use { c ->
            if (c.moveToFirst()) {
                val row = Array<Any?>(columns.size) { i ->
                    when (columns[i]) {
                        OpenableColumns.DISPLAY_NAME -> displayName
                        else -> c.getColumnValue(columns[i])
                    }
                }
                out.addRow(row)
            }
        }
        return out
    }
}

private fun Cursor.getColumnValue(columnName: String): Any? {
    val index = getColumnIndex(columnName)
    if (index < 0) return null
    return when (getType(index)) {
        Cursor.FIELD_TYPE_INTEGER -> getLong(index)
        Cursor.FIELD_TYPE_FLOAT -> getDouble(index)
        Cursor.FIELD_TYPE_STRING -> getString(index)
        Cursor.FIELD_TYPE_BLOB -> getBlob(index)
        Cursor.FIELD_TYPE_NULL -> null
        else -> getString(index)
    }
}
