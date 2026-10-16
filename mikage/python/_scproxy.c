/* iOS stand-in for CPython's macOS-only _scproxy module, which
 * urllib.request imports on Darwin. iOS has no system proxy settings Python
 * can read, so it reports none (after renpy-build's _scproxy.pyx). */

#include <Python.h>

static PyObject *
get_proxy_settings(PyObject *module, PyObject *unused)
{
    return Py_BuildValue("{s:i}", "exclude_simple", 1);
}

static PyObject *
get_proxies(PyObject *module, PyObject *unused)
{
    return PyDict_New();
}

static PyMethodDef scproxy_methods[] = {
    {"_get_proxy_settings", get_proxy_settings, METH_NOARGS, NULL},
    {"_get_proxies", get_proxies, METH_NOARGS, NULL},
    {NULL, NULL, 0, NULL},
};

static struct PyModuleDef scproxy_module = {
    PyModuleDef_HEAD_INIT, "_scproxy", NULL, -1, scproxy_methods,
};

PyMODINIT_FUNC
PyInit__scproxy(void)
{
    return PyModule_Create(&scproxy_module);
}
